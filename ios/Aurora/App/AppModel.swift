import BackgroundTasks
import Foundation
import UIKit
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
        ble.onUnsolicitedConnect = { [weak self] in
            Task { await self?.handleScheduledWake() }
        }
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
        await syncNow(userInitiated: false)
    }

    /// Sync with the ring, retrying link failures.
    ///
    /// A worn ring advertises rarely and can drop the link mid-download, so a
    /// single attempt fails often. Each retry tears the link down and reconnects;
    /// the stored cursor makes a retried download resume, not restart. Automatic
    /// (launch / background) syncs that cannot reach the ring fail quietly: the ring
    /// is simply not nearby.
    func syncNow(userInitiated: Bool = true) async {
        guard let key = Keychain.get(Keychain.ringKeyAccount), !syncPhase.isBusy else { return }
        let maxAttempts = userInitiated ? 3 : 2
        var lastError: Error?
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                ble.disconnect()
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
            syncPhase = .connecting
            do {
                try await syncOnce(key: key)
                return
            } catch {
                lastError = error
                DiagnosticsLog.shared.add("sync attempt \(attempt) failed: \(error.localizedDescription)")
                log.error("sync attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                if !Self.isRetryable(error) { break }
            }
        }
        let message = lastError?.localizedDescription ?? "Sync failed."
        if !userInitiated, let lastError, Self.isRetryable(lastError) {
            syncPhase = .idle // ring out of range: not worth an alarm
        } else {
            syncPhase = .failed(message)
        }
    }

    /// Link problems are worth another try; a rejected key or a full disk is not.
    static func isRetryable(_ error: Error) -> Bool {
        if let ble = error as? RingBluetooth.BLEError {
            if case .bluetoothUnavailable = ble { return false }
            return true
        }
        if let core = error as? CoreError {
            switch core {
            case .Link, .Ring: return true
            case .Auth, .Store, .InvalidKey: return false
            }
        }
        return error is CancellationError ? false : true
    }

    private func syncOnce(key: String) async throws {
        DiagnosticsLog.shared.add("sync: connecting")
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
        DiagnosticsLog.shared.add("sync ok: \(report.eventsReceived) events, \(report.newEvents) new, warnings \(report.warnings)")
        await connectors.exportAll()
    }

    // MARK: - Continuous (5-minute) sync

    static let continuousInterval: TimeInterval = 5 * 60

    /// Sync about every five minutes, also in the background. On by default.
    var continuousSync: Bool = UserDefaults.standard.object(forKey: "sync.continuous") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(continuousSync, forKey: "sync.continuous")
            if continuousSync { scheduleNextWake() } else { ble.cancelWake() }
        }
    }

    private var foregroundTimer: Timer?
    private(set) var isInForeground = true

    /// The app went to the background: hand the cadence to the Bluetooth system.
    func didEnterBackground() {
        isInForeground = false
        foregroundTimer?.invalidate()
        foregroundTimer = nil
        if continuousSync, hasKey, !isStreamingHeartRate { scheduleNextWake() }
    }

    func didBecomeActive() {
        isInForeground = true
        foregroundTimer?.invalidate()
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.continuousSync, !self.isStreamingHeartRate else { return }
                await self.syncIfStale(minimumInterval: Self.continuousInterval - 15)
            }
        }
        Task { await syncIfStale(minimumInterval: continuousSync ? Self.continuousInterval - 15 : 15 * 60) }
    }

    private func scheduleNextWake() {
        let since = lastSync.map { Date.now.timeIntervalSince($0) } ?? Self.continuousInterval
        ble.scheduleWake(after: max(5, Self.continuousInterval - since))
    }

    /// The delayed connection fired: sync, then schedule the next one. iOS gives a
    /// woken background app only seconds, so ask for the extended background window.
    func handleScheduledWake() async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "aurora.sync")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        DiagnosticsLog.shared.add("scheduled wake: syncing (foreground=\(isInForeground))")
        await syncNow(userInitiated: false)
        if !isInForeground && continuousSync { scheduleNextWake() }
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
        ble.cancelWake()
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

    /// Live heart rate: `liveIsFallback` is true while the value shown is the ring's
    /// latest automatic reading rather than a live beat.
    private(set) var liveIsFallback = false
    private(set) var liveError: String?
    private(set) var liveStatus: String?
    private var liveSession: RingSession?

    func streamHeartRate(seconds: UInt32 = 120) async {
        guard let key = Keychain.get(Keychain.ringKeyAccount), !isStreamingHeartRate else { return }
        isStreamingHeartRate = true
        liveHeartRate = nil
        liveError = nil
        liveIsFallback = false
        liveStatus = "Connecting to your ring…"
        defer {
            isStreamingHeartRate = false
            liveSession = nil
            liveStatus = nil
        }
        do {
            let session = try await connectWithRetry()
            liveSession = session
            liveStatus = "Waiting for beats. Keep the ring snug and your hand still."
            let listener = LiveHeartRate { [weak self] bpm, live in
                guard let self, self.isStreamingHeartRate else { return }
                self.liveHeartRate = bpm
                self.liveIsFallback = !live
                self.liveStatus = live ? nil : "Latest automatic reading. Live beats haven't arrived yet."
            }
            let beats = try await session.liveHeartRate(keyHex: key, seconds: seconds, listener: listener)
            DiagnosticsLog.shared.add("live HR ended: \(beats) live beats")
            if beats == 0 && liveHeartRate == nil {
                liveError = "No heart-rate readings arrived. Make sure the ring is on your finger and snug, then try again."
            }
        } catch {
            DiagnosticsLog.shared.add("live HR failed: \(error.localizedDescription)")
            log.error("live HR: \(error.localizedDescription, privacy: .public)")
            liveError = error.localizedDescription
        }
    }

    func stopHeartRate() {
        liveSession?.stopLiveHeartRate()
    }

    /// Connect, retrying once after tearing down a possibly stale link.
    private func connectWithRetry() async throws -> RingSession {
        do {
            return try await ble.connect()
        } catch let error as RingBluetooth.BLEError {
            if case .bluetoothUnavailable = error { throw error }
            ble.disconnect()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return try await ble.connect()
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
    /// `(bpm, isLiveBeat)`; a reading with `ibiMs == 0` is the ring's latest automatic value.
    private let update: @MainActor (UInt16, Bool) -> Void
    init(update: @escaping @MainActor (UInt16, Bool) -> Void) { self.update = update }
    func onHeartRate(bpm: UInt16, ibiMs: UInt16) {
        Task { @MainActor in update(bpm, ibiMs > 0) }
    }
}
