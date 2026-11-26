import Foundation

/// An export target for ring data (Nocturne, Trio, ...).
///
/// Connectors never talk to the ring or the database directly. The
/// ``ConnectorManager`` pages new ``Sample``s out of the store (by sample id, with
/// a persisted cursor per connector) and hands each page to ``upload(_:)``. A
/// connector only has to turn samples into its service's format.
///
/// Adding a connector:
/// 1. Implement this protocol (see `NocturneConnector`).
/// 2. Register it in ``ConnectorManager/init(store:)``.
/// 3. Add a settings view in `ConnectorsView`.
@MainActor
protocol HealthConnector: AnyObject {
    /// Stable identifier. Used as the database cursor key: never change it.
    var id: String { get }
    var displayName: String { get }
    /// One line for the connector list.
    var tagline: String { get }
    var symbol: String { get }
    /// Metric kinds this connector exports (given its current settings).
    var exportedKinds: [MetricKind] { get }
    /// Whether the user has filled in what the connector needs.
    var isConfigured: Bool { get }
    /// Whether it is implemented in this build (false = shown as "coming soon").
    var isAvailable: Bool { get }
    var isEnabled: Bool { get set }

    /// Send one page of samples (oldest first, all of `exportedKinds`). Throwing
    /// leaves the cursor where it was, so the same page is retried next time.
    func upload(_ samples: [Sample]) async throws

    /// Check the settings against the service; returns a human-readable success message.
    func testConnection() async throws -> String
}

/// Outcome of the last export run of one connector, shown in the UI.
struct ConnectorStatus: Codable, Equatable {
    var lastRun: Date
    var exported: Int
    var error: String?
    /// The last run that actually sent something, and the newest reading it sent.
    /// A run with nothing new keeps these, so "sent 0" doesn't hide recent uploads.
    var lastSentAt: Date?
    var lastSentCount: Int?
    var newestSentReading: Date?
}

@MainActor
@Observable
final class ConnectorManager {
    private(set) var connectors: [any HealthConnector]
    private(set) var statuses: [String: ConnectorStatus] = [:]
    private(set) var isExporting = false

    private let store: AuroraStore
    private let pageSize: UInt32 = 500

    init(store: AuroraStore) {
        self.store = store
        connectors = [NocturneConnector(), TrioConnector()]
        if let data = UserDefaults.standard.data(forKey: "aurora.connector.statuses"),
           let saved = try? JSONDecoder().decode([String: ConnectorStatus].self, from: data) {
            statuses = saved
        }
    }

    func connector(id: String) -> (any HealthConnector)? {
        connectors.first { $0.id == id }
    }

    /// Export everything new to every enabled, configured connector.
    func exportAll() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        for c in connectors where c.isAvailable && c.isEnabled && c.isConfigured {
            await export(c)
        }
    }

    /// Start a connector over from the first sample (e.g. after changing servers).
    func resetCursor(for connector: any HealthConnector) {
        try? store.setConnectorCursor(connectorId: connector.id, cursor: 0)
    }

    private func export(_ c: any HealthConnector) async {
        var exported = 0
        var errorText: String?
        var newest: Double?
        do {
            var cursor = try store.connectorCursor(connectorId: c.id)
            while true {
                let page = try store.samplesAfter(afterId: cursor, kinds: c.exportedKinds, limit: pageSize)
                guard let last = page.last else { break }
                try await c.upload(page)
                newest = max(newest ?? 0, page.map(\.ts).max() ?? 0)
                cursor = last.id
                try store.setConnectorCursor(connectorId: c.id, cursor: cursor)
                exported += page.count
                if page.count < pageSize { break }
            }
        } catch {
            errorText = userMessage(for: error)
        }
        var status = statuses[c.id] ?? ConnectorStatus(lastRun: .now, exported: 0)
        status.lastRun = .now
        status.exported = exported
        status.error = errorText
        if exported > 0 {
            status.lastSentAt = .now
            status.lastSentCount = exported
            if let newest { status.newestSentReading = Date(timeIntervalSince1970: newest) }
        }
        statuses[c.id] = status
        if let data = try? JSONEncoder().encode(statuses) {
            UserDefaults.standard.set(data, forKey: "aurora.connector.statuses")
        }
    }
}
