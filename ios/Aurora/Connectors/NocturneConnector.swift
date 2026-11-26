import CryptoKit
import Foundation

/// Uploads ring data to a Nocturne server (https://getnocturne.dev), the
/// Nightscout-compatible diabetes platform.
///
/// Uses Nocturne's V4 health API:
/// * `POST /api/v4/HeartRate`: an array of `{timestamp, utcOffset, bpm, accuracy,
///   device, app, dataSource, syncIdentifier}`.
/// * `POST /api/v4/StepCount`: an array of `{timestamp, utcOffset, metric, source,
///   device, app, dataSource, syncIdentifier}` (optional, from MET estimates).
///
/// Every record carries `dataSource` + a deterministic `syncIdentifier`, so Nocturne
/// updates a re-sent record in place instead of duplicating it. That makes retries
/// and "export everything again" safe.
///
/// Authentication: the `api-secret` header. A Nocturne access token (`noc_…`) is sent
/// as-is; a legacy Nightscout API secret is sent SHA-1 hashed, as Nightscout expects.
/// The token needs write access to health data.
@MainActor
@Observable
final class NocturneConnector: HealthConnector {
    let id = "nocturne"
    let displayName = "Nocturne"
    let tagline = "Heart rate (and optional step estimates) to your Nocturne site"
    let symbol = "moon.haze.fill"
    let isAvailable = true

    static let dataSource = "aurora-oura-ring"

    private let defaults = UserDefaults.standard
    private let session: URLSession

    var baseURLString: String {
        didSet { defaults.set(baseURLString, forKey: "nocturne.url") }
    }
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "nocturne.enabled") }
    }
    var exportSteps: Bool {
        didSet { defaults.set(exportSteps, forKey: "nocturne.steps") }
    }
    /// Stored in the Keychain, never in UserDefaults.
    var token: String {
        didSet {
            if token.isEmpty { Keychain.delete("nocturne.token") } else { try? Keychain.set(token, for: "nocturne.token") }
        }
    }

    init(session: URLSession = .shared) {
        self.session = session
        baseURLString = UserDefaults.standard.string(forKey: "nocturne.url") ?? ""
        isEnabled = UserDefaults.standard.bool(forKey: "nocturne.enabled")
        exportSteps = UserDefaults.standard.bool(forKey: "nocturne.steps")
        token = Keychain.get("nocturne.token") ?? ""
    }

    var exportedKinds: [MetricKind] {
        exportSteps ? [.heartRate, .activityMet] : [.heartRate]
    }

    var baseURL: URL? {
        var s = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    var isConfigured: Bool { baseURL != nil && !token.isEmpty }

    // MARK: HealthConnector

    func upload(_ samples: [Sample]) async throws {
        let device = UserDefaults.standard.string(forKey: "aurora.ring.model") ?? "Oura Ring"
        let hr = Self.heartRateRecords(samples, device: device)
        let steps = exportSteps ? Self.stepRecords(samples, device: device) : []
        for chunk in hr.chunked(into: 250) { try await post(chunk, to: "api/v4/HeartRate") }
        for chunk in steps.chunked(into: 250) { try await post(chunk, to: "api/v4/StepCount") }
    }

    func testConnection() async throws -> String {
        var request = try makeRequest(path: "api/v4/HeartRate")
        request.url = request.url.flatMap {
            var c = URLComponents(url: $0, resolvingAgainstBaseURL: false)
            c?.queryItems = [URLQueryItem(name: "count", value: "1")]
            return c?.url
        }
        let (_, response) = try await session.data(for: request)
        try Self.check(response, data: nil)
        return "Connected to \(baseURL?.host() ?? "Nocturne")."
    }

    // MARK: Mapping (static + pure, so it is unit-tested)

    struct HeartRateRecord: Codable, Equatable {
        var timestamp: String
        var utcOffset: Int
        var bpm: Int
        var accuracy: Int
        var device: String
        var app: String
        var dataSource: String
        var syncIdentifier: String
    }

    struct StepCountRecord: Codable, Equatable {
        var timestamp: String
        var utcOffset: Int
        /// Steps in this record's interval (a delta: `source` bit 0 clear).
        var metric: Int
        var source: Int
        var device: String
        var app: String
        var dataSource: String
        var syncIdentifier: String
    }

    static func heartRateRecords(_ samples: [Sample], device: String, timeZone: TimeZone = .current) -> [HeartRateRecord] {
        samples.filter { $0.kind == .heartRate }.map { s in
            let date = Date(timeIntervalSince1970: s.ts)
            return HeartRateRecord(
                timestamp: iso8601(date),
                utcOffset: timeZone.secondsFromGMT(for: date) / 60,
                bpm: Int(s.value.rounded()),
                accuracy: 1,
                device: device,
                app: "Aurora",
                dataSource: dataSource,
                syncIdentifier: "hr-\(Int(s.ts.rounded()))"
            )
        }
    }

    /// Steps estimated from one-minute MET values (the ring has no step counter in
    /// its event stream; this is the same cadence rule the app's dashboard uses).
    static func stepRecords(_ samples: [Sample], device: String, timeZone: TimeZone = .current) -> [StepCountRecord] {
        samples.filter { $0.kind == .activityMet }.compactMap { s in
            let steps = s.value >= 7 ? 150 : (s.value >= 2.5 ? 105 : 0)
            guard steps > 0 else { return nil }
            let date = Date(timeIntervalSince1970: s.ts)
            return StepCountRecord(
                timestamp: iso8601(date),
                utcOffset: timeZone.secondsFromGMT(for: date) / 60,
                metric: steps,
                source: 0,
                device: device,
                app: "Aurora",
                dataSource: dataSource,
                syncIdentifier: "steps-\(Int(s.ts.rounded()))"
            )
        }
    }

    /// The `api-secret` header value for a token or legacy secret.
    static func apiSecretHeader(for token: String) -> String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("noc_") { return t }
        // Already a 40-char SHA-1 hex digest? Send it through.
        if t.count == 40, t.allSatisfy(\.isHexDigit) { return t.lowercased() }
        return Insecure.SHA1.hash(data: Data(t.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: HTTP

    enum NocturneError: LocalizedError {
        case notConfigured
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your Nocturne address and access token first."
            case .http(401, _), .http(403, _):
                "Nocturne refused the token. Make sure it can write health data."
            case .http(let code, let body): "Nocturne answered \(code). \(body.prefix(200))"
            }
        }
    }

    private func makeRequest(path: String) throws -> URLRequest {
        guard let base = baseURL, !token.isEmpty else { throw NocturneError.notConfigured }
        var request = URLRequest(url: base.appending(path: path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiSecretHeader(for: token), forHTTPHeaderField: "api-secret")
        request.timeoutInterval = 30
        return request
    }

    private func post<T: Encodable>(_ records: [T], to path: String) async throws {
        guard !records.isEmpty else { return }
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(records)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
    }

    private static func check(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NocturneError.http(http.statusCode, data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
