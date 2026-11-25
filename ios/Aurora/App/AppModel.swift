import BackgroundTasks
import Foundation
import Observation
import os

/// App-wide state: the database, the ring link, sync and the selected day.
@MainActor
@Observable
final class AppModel {
    enum SyncPhase: Equatable {
        case idle
        case connecting
        case running(stage: SyncStage, events: UInt32, bytesLeft: UInt32)
        case finished(SyncReport)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .connecting, .running: true
            default: false
            }
        }
    }

    static let backgroundSyncTask = "com.aurorafarming.aurora.sync"

    let store: AuroraStore
    let connectors: ConnectorManager
    private let ble = RingBluetooth()
    private let log = Logger(subsystem: "Aurora", category: "App")

    private(set) var linkState: RingBluetooth.State = .idle
    private(set) var syncPhase: SyncPhase = .idle
    private(set) var hasKey: Bool = Keychain.get(Keychain.ringKeyAccount) != nil
    private(set) var device: StoredDevice?
    private(set) var ringInfo: RingInfo?
    private(set) var battery: BatteryStatus?
    private(set) var liveHeartRate: UInt16?
    private(set) var isStreamingHeartRate = false
    /// Bumped after every sync so views reload their queries.
    private(set) var dataVersion = 0

    var selectedDay: Date = Calendar.current.startOfDay(for: .now)

    var lastSync: Date? {
        guard let d = device, d.lastSyncUnix > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(d.lastSyncUnix))
    }

    var weightKg: Double {
        let w = UserDefaults.standard.double(forKey: "profile.weightKg")
        return w > 0 ? w : 75
    }

    init() {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "aurora.db").path(percentEncoded: false)
        do {
            store = try AuroraStore.open(path: path)
        } catch {
            // A database that cannot open is unrecoverable for this launch; fall back
            // to an in-memory-like temp store so the UI can still explain the problem.
            Logger(subsystem: "Aurora", category: "App").fault("db open failed: \(error.localizedDescription)")
            let tmp = FileManager.default.temporaryDirectory.appending(path: "aurora-fallback.db")
            store = try! AuroraStore.open(path: tmp.path(percentEncoded: false))
        }
        connectors = ConnectorManager(store: store)
        device = try? store.device()
        ble.onStateChange = { [weak self] state in self?.linkState = state }
    }

    // MARK: - Day navigation

    func summary(for day: Date) -> DaySummary? {
        _ = dataVersion
        return try? store.daySummary(dayStart: Calendar.current.startOfDay(for: day).timeIntervalSince1970,
                                     weightKg: weightKg)
    }

    func buckets(_ kind: MetricKind, from: Date, to: Date, bucket: TimeInterval) -> [Bucket] {
        _ = dataVersion
        let offset = Int32(TimeZone.current.secondsFromGMT(for: from))
        return (try? store.buckets(kind: kind, from: from.timeIntervalSince1970, to: to.timeIntervalSince1970,
                                   bucketSeconds: UInt32(bucket), tzOffsetSeconds: offset)) ?? []
    }

    func samples(_ kind: MetricKind, from: Date, to: Date, limit: UInt32 = 5000) -> [Sample] {
        _ = dataVersion
        return (try? store.samples(kind: kind, from: from.timeIntervalSince1970, to: to.timeIntervalSince1970,
                                   limit: limit)) ?? []
    }

    func latest(_ kind: MetricKind) -> Sample? {
        _ = dataVersion
        return try? store.latest(kind: kind)
    }

    // MARK: - Sync

    /// Sync if the last one is older than `minimumInterval`.
    func syncIfStale(minimumInterval: TimeInterval = 15 * 60) async {
        guard hasKey, !syncPhase.isBusy else { return }
        if let last = lastSync, Date.now.timeIntervalSince(last) < minimumInterval { return }
        await syncNow()
    }

    func syncNow() async {
        guard let key = Keychain.get(Keychain.ringKeyAccount), !syncPhase.isBusy else { return }
        syncPhase = .connecting
        do {
            let session = try await ble.connect()
            if ringInfo == nil { ringInfo = try? await session.info() }
            if let info = ringInfo {
                UserDefaults.standard.set(info.isRing5 ? "Oura Ring 5" : "Oura Ring (\(info.hardwareId))",
                                          forKey: "aurora.ring.model")
            }
            let listener = SyncProgress { [weak self] phase in
                // Callbacks hop to the main actor and can land after the sync returned.
                guard let self, case .running = self.syncPhase else { return }
                self.syncPhase = phase
            }
            syncPhase = .running(stage: .authenticating, events: 0, bytesLeft: 0)
            let report = try await session.sync(keyHex: key, store: store, listener: listener)
            if let pct = report.batteryPercent {
                battery = BatteryStatus(percent: pct, chargingProgress: battery?.chargingProgress ?? 0,
                                        chargingRecommended: pct < 20)
            }
            device = try? store.device()
            dataVersion += 1
            syncPhase = .finished(report)
            await connectors.exportAll()
        } catch {
            log.error("sync failed: \(error.localizedDescription, privacy: .public)")
            syncPhase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Pairing

    enum RingCheck: Equatable {
        case ready(RingInfo)
        case factoryReset(RingInfo)
        case wrongKey(RingInfo)
        case otherDevice(RingInfo)
    }

    /// Connect and ask the ring about the stored key (or a throwaway one).
    func checkRing() async throws -> RingCheck {
        let session = try await ble.connect()
        let info = try await session.info()
        ringInfo = info
        let probeKey = try Keychain.get(Keychain.ringKeyAccount) ?? generateAuthKey()
        switch try await session.keyStatus(keyHex: probeKey) {
        case .accepted: return .ready(info)
        case .factoryReset: return .factoryReset(info)
        case .otherDevice: return .otherDevice(info)
        case .wrongKey, .unknown: return .wrongKey(info)
        }
    }

    /// Pair a factory-reset ring with a fresh key. Returns non-fatal warnings.
    func pairFactoryResetRing() async throws -> [String] {
        let session = try await ble.connect()
        // Reuse a key left over from an interrupted pairing (it may already be on the
        // ring), like open_oura's `pair` does; otherwise mint one. Keep it before
        // installing it: once on the ring it is the only way in.
        let key = try Keychain.get(Keychain.ringKeyAccount) ?? generateAuthKey()
        try Keychain.set(key, for: Keychain.ringKeyAccount)
        do {
            let warnings = try await session.pair(keyHex: key)
            hasKey = true
            ringInfo = try? await session.info()
            if let serial = ringInfo?.serial { try? store.resetSyncCursor(serial: serial) }
            return warnings
        } catch {
            // If the ring accepted the key but verification failed we must not lose it,
            // so only discard it when the ring refused the key outright.
            let refused: Bool
            if let core = error as? CoreError, case .Auth = core { refused = true } else { refused = false }
            if refused, (try? await session.keyStatus(keyHex: key)) != .accepted {
                Keychain.delete(Keychain.ringKeyAccount)
            }
            throw error
        }
    }

    /// Use a key exported from the official app (or a previous Aurora install).
    func useExistingKey(_ hex: String) async throws -> Bool {
        guard isValidAuthKey(hexKey: hex) else { throw CoreError.InvalidKey }
        let cleaned = hex.filter(\.isHexDigit).lowercased()
        let session = try await ble.connect()
        let status = try await session.keyStatus(keyHex: cleaned)
        guard status == .accepted else { return false }
        try Keychain.set(cleaned, for: Keychain.ringKeyAccount)
        hasKey = true
        ringInfo = try? await session.info()
        return true
    }

    func forgetRing() {
        Keychain.delete(Keychain.ringKeyAccount)
        hasKey = false
        ringInfo = nil
        battery = nil
        ble.forgetRing()
    }

    // MARK: - Live

    func refreshBattery() async {
        guard let key = Keychain.get(Keychain.ringKeyAccount) else { return }
        do {
            let session = try await ble.connect()
            battery = try await session.battery(keyHex: key)
        } catch {
            log.error("battery: \(error.localizedDescription, privacy: .public)")
        }
    }

    func features() async throws -> [FeatureState] {
        guard let key = Keychain.get(Keychain.ringKeyAccount) else { return [] }
        return try await ble.connect().features(keyHex: key)
    }

    func enableMeasurements() async throws -> [String] {
        guard let key = Keychain.get(Keychain.ringKeyAccount) else { return [] }
        return try await ble.connect().enableMeasurements(keyHex: key)
    }

    func streamHeartRate(seconds: UInt32 = 60) async {
        guard let key = Keychain.get(Keychain.ringKeyAccount), !isStreamingHeartRate else { return }
        isStreamingHeartRate = true
        liveHeartRate = nil
        defer { isStreamingHeartRate = false }
        do {
            let session = try await ble.connect()
            let listener = LiveHeartRate { [weak self] bpm in self?.liveHeartRate = bpm }
            try await session.liveHeartRate(keyHex: key, seconds: seconds, listener: listener)
        } catch {
            log.error("live HR: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Maintenance

    func rebuildSamples() throws -> UInt32 {
        let n = try store.rebuildSamples()
        dataVersion += 1
        return n
    }

    func exportDatabase() throws -> URL {
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appending(path: "aurora-ring-\(stamp).db")
        try store.exportCopy(destPath: url.path(percentEncoded: false))
        return url
    }

    // MARK: - Background refresh

    static func registerBackgroundSync(model: @escaping @MainActor () -> AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundSyncTask, using: nil) { task in
            scheduleBackgroundSync()
            let work = Task { @MainActor in
                await model().syncIfStale(minimumInterval: 30 * 60)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundSyncTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Bridges Rust sync callbacks (background thread) to the main actor.
private final class SyncProgress: SyncListener, @unchecked Sendable {
    private let update: @MainActor (AppModel.SyncPhase) -> Void
    private let lock = NSLock()
    private var stage: SyncStage = .authenticating
    private var events: UInt32 = 0
    private var bytesLeft: UInt32 = 0

    init(update: @escaping @MainActor (AppModel.SyncPhase) -> Void) { self.update = update }

    func onStage(stage: SyncStage) {
        lock.lock(); self.stage = stage; let p = snapshot(); lock.unlock()
        Task { @MainActor in update(p) }
    }

    func onProgress(eventsSynced: UInt32, bytesLeft: UInt32) {
        lock.lock(); events = eventsSynced; self.bytesLeft = bytesLeft; let p = snapshot(); lock.unlock()
        Task { @MainActor in update(p) }
    }

    private func snapshot() -> AppModel.SyncPhase {
        .running(stage: stage, events: events, bytesLeft: bytesLeft)
    }
}

private final class LiveHeartRate: HeartRateListener, @unchecked Sendable {
    private let update: @MainActor (UInt16) -> Void
    init(update: @escaping @MainActor (UInt16) -> Void) { self.update = update }
    func onHeartRate(bpm: UInt16, ibiMs: UInt16) {
        Task { @MainActor in update(bpm) }
    }
}
