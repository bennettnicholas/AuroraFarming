import CoreBluetooth
import Foundation
import os

/// CoreBluetooth side of the ring link.
///
/// Finds the ring, connects, subscribes to every notify/indicate characteristic in
/// the Oura service, and hands the Rust core a ``RingSession`` whose writes go to
/// the ring's write characteristic. Every notification is forwarded into that
/// session; the Rust core (open_oura's client) does all protocol work.
///
/// All CoreBluetooth calls happen on a private serial queue so the main thread is
/// never on the data path of a history download.
final class RingBluetooth: NSObject, @unchecked Sendable {
    enum State: Equatable {
        case poweredOff
        case unauthorized
        case unsupported
        case idle
        case scanning
        case connecting
        case connected(name: String)
    }

    enum BLEError: LocalizedError {
        case bluetoothUnavailable(String)
        case notFound
        case timeout
        case disconnected(String?)
        case missingCharacteristic

        var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable(let why): return "Bluetooth is unavailable: \(why)."
            case .notFound: return "No Oura ring found nearby. Put the ring on its charger to wake it and try again."
            case .timeout: return "Couldn't reach the ring. On your finger it only advertises every few seconds and can be busy measuring; keep the phone close, or put the ring on its charger, and try again."
            case .disconnected(let why): return "The ring disconnected\(why.map { ": \($0)" } ?? ".")"
            case .missingCharacteristic: return "This ring does not expose the expected Oura Bluetooth service."
            }
        }
    }

    /// Oura GATT layout (Ring 3/4/5 share it; see open_oura docs/ring-5-observations.md).
    static let serviceUUID = CBUUID(string: "98ED0001-A541-11E4-B6A0-0002A5D5C51B")
    static let writeUUID = CBUUID(string: "98ED0002-A541-11E4-B6A0-0002A5D5C51B")

    private static let rememberedKey = "aurora.ring.peripheral"
    private let log = Logger(subsystem: "Aurora", category: "BLE")
    private let queue = DispatchQueue(label: "aurora.ble")
    private var central: CBCentralManager!

    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var pendingNotifySubscriptions = 0
    /// The remembered ring we asked iOS to connect to while also scanning.
    private var pendingRemembered: CBPeripheral?
    private var session: RingSession?

    private var poweredOnWaiters: [CheckedContinuation<Void, Error>] = []
    private var connectContinuation: CheckedContinuation<RingSession, Error>?
    /// Callers that asked to connect while a connect was already in progress. They
    /// share its outcome instead of cancelling it (two Ring-tab cards loading at once
    /// used to cancel each other).
    private var extraWaiters: [CheckedContinuation<RingSession, Error>] = []
    /// When the current session became ready; a fresh one (from a scheduled wake) is reused.
    private var sessionReadyAt: Date?
    /// A delayed connect is armed and has not produced a ready session yet.
    private var wakePending = false

    /// Called on the main actor whenever the link state changes.
    var onStateChange: (@MainActor (State) -> Void)?
    private let diag = DiagnosticsLog.shared
    private(set) var state: State = .idle {
        didSet {
            let s = state
            if s != oldValue { diag.add("ble state: \(s)") }
            if let cb = onStateChange { Task { @MainActor in cb(s) } }
        }
    }

    override init() {
        super.init()
        // State restoration: if iOS terminates Aurora while a (delayed) connection is
        // pending, it relaunches the app in the background when that connection completes.
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.aurorafarming.aurora.central",
        ])
    }

    /// Called on the main actor when the ring connects without anyone waiting for
    /// it, i.e. a scheduled wake fired (possibly after iOS relaunched the app).
    var onUnsolicitedConnect: (@MainActor () -> Void)?

    /// Drop the current link and ask iOS to reconnect to the ring in `seconds`.
    ///
    /// This is the 5-minute cadence. It uses `CBConnectPeripheralOptionStartDelayKey`
    /// (iOS 17): the delay is kept by the Bluetooth system, not by an app timer, so it
    /// runs while Aurora is suspended, and with state restoration even after iOS has
    /// terminated it. When the connection completes, iOS wakes the app and
    /// ``onUnsolicitedConnect`` fires.
    func scheduleWake(after seconds: TimeInterval) {
        queue.async {
            guard self.connectContinuation == nil else { return } // a connect is in progress
            guard let id = self.rememberedPeripheral,
                  let p = self.central.retrievePeripherals(withIdentifiers: [id]).first else { return }
            if let current = self.peripheral, current.state != .disconnected {
                self.central.cancelPeripheralConnection(current)
            }
            self.reset()
            self.peripheral = p
            p.delegate = self
            self.central.connect(p, options: [CBConnectPeripheralOptionStartDelayKey: max(1, Int(seconds))])
            self.wakePending = true
            self.diag.add("wake scheduled in \(Int(seconds)) s")
            self.state = .idle
        }
    }

    /// Cancel a scheduled wake (continuous sync turned off, ring forgotten).
    func cancelWake() {
        queue.async {
            guard self.connectContinuation == nil, let p = self.peripheral, self.session == nil else { return }
            self.wakePending = false
            self.central.cancelPeripheralConnection(p)
            self.reset()
            self.diag.add("wake cancelled")
        }
    }

    var rememberedPeripheral: UUID? {
        UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:))
    }

    func forgetRing() {
        UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
        disconnect()
    }

    /// Connect to the ring (the remembered one if possible, otherwise the strongest
    /// one advertising) and return a session ready for protocol calls.
    func connect(timeout: TimeInterval = 45) async throws -> RingSession {
        try await waitForPoweredOn()
        if let session = queue.sync(execute: { self.isReady ? self.session : nil }) {
            return session
        }
        return try await withThrowingTaskGroup(of: RingSession.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.queue.async { self.beginConnect(cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BLEError.timeout
            }
            do {
                let session = try await group.next()!
                group.cancelAll()
                return session
            } catch {
                group.cancelAll()
                queue.async { self.fail(error) }
                throw error
            }
        }
    }

    func disconnect() {
        queue.async {
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.reset()
            self.state = .idle
        }
    }

    // MARK: - Internals (on `queue`)

    private var isReady: Bool {
        peripheral?.state == .connected && writeCharacteristic != nil && pendingNotifySubscriptions == 0
            && session != nil
    }

    private func waitForPoweredOn() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                switch self.central.state {
                case .poweredOn: cont.resume()
                case .unknown, .resetting: self.poweredOnWaiters.append(cont)
                case .unauthorized:
                    cont.resume(throwing: BLEError.bluetoothUnavailable("Aurora is not allowed to use Bluetooth (Settings > Aurora)"))
                case .unsupported:
                    cont.resume(throwing: BLEError.bluetoothUnavailable("this device has no Bluetooth LE"))
                case .poweredOff:
                    cont.resume(throwing: BLEError.bluetoothUnavailable("Bluetooth is turned off"))
                @unknown default:
                    cont.resume(throwing: BLEError.bluetoothUnavailable("unknown state"))
                }
            }
        }
    }

    private func beginConnect(_ cont: CheckedContinuation<RingSession, Error>) {
        if connectContinuation != nil {
            diag.add("connect: joining the connect in progress")
            extraWaiters.append(cont)
            return
        }
        connectContinuation = cont
        // A scheduled wake just brought the ring up: use that link instead of tearing it down.
        if let s = session, let p = peripheral, p.state == .connected, writeCharacteristic != nil,
           let readyAt = sessionReadyAt, Date.now.timeIntervalSince(readyAt) < 60 {
            diag.add("connect: reusing link from scheduled wake")
            connectContinuation = nil
            cont.resume(returning: s)
            return
        }
        wakePending = false
        diag.add("connect: start (remembered=\(rememberedPeripheral?.uuidString ?? "none"))")
        // Drop any half-open link first: a peripheral iOS still calls "connected"
        // after the ring silently went away makes every request time out.
        if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
        reset()

        // A ring already connected to iOS (e.g. by another app) is the fastest path.
        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            connectTo(connected)
            return
        }
        // Otherwise do both at once: a pending connect to the remembered ring (iOS
        // completes it the moment the ring advertises, however rarely) AND a scan,
        // in case the ring's identifier changed (re-pairing, iOS Bluetooth reset).
        // A worn ring can advertise only every few seconds, so this can take a while.
        if let id = rememberedPeripheral,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            pendingRemembered = known
            known.delegate = self
            central.connect(known, options: nil)
            state = .connecting
        } else {
            state = .scanning
        }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func connectTo(_ p: CBPeripheral) {
        central.stopScan()
        if let other = pendingRemembered, other.identifier != p.identifier {
            central.cancelPeripheralConnection(other)
        }
        pendingRemembered = nil
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: nil)
    }

    private func reset() {
        session = nil
        sessionReadyAt = nil
        writeCharacteristic = nil
        pendingNotifySubscriptions = 0
        peripheral = nil
    }

    private func fail(_ error: Error) {
        diag.add("connect failed: \(error.localizedDescription)")
        central.stopScan()
        if let p = pendingRemembered, p.state != .disconnected { central.cancelPeripheralConnection(p) }
        pendingRemembered = nil
        if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
        reset()
        state = .idle
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        let waiters = extraWaiters
        extraWaiters = []
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func finishIfReady() {
        guard let p = peripheral, writeCharacteristic != nil, pendingNotifySubscriptions == 0,
              session == nil else { return }
        let link = Link(owner: self)
        let s = RingSession(link: link)
        session = s
        sessionReadyAt = .now
        wakePending = false
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.rememberedKey)
        state = .connected(name: p.name ?? "Oura Ring")
        log.info("ring ready: \(p.name ?? "?", privacy: .public)")
        diag.add("ring ready: \(p.name ?? "?") \(p.identifier.uuidString)")
        if let cont = connectContinuation {
            cont.resume(returning: s)
            connectContinuation = nil
            let waiters = extraWaiters
            extraWaiters = []
            waiters.forEach { $0.resume(returning: s) }
        } else if let cb = onUnsolicitedConnect {
            diag.add("scheduled wake: ring connected")
            Task { @MainActor in cb() }
        }
    }

    /// Called by the Rust core (any thread) to send a request frame.
    fileprivate func write(_ data: Data) -> Bool {
        var ok = false
        queue.sync {
            guard let p = peripheral, p.state == .connected, let c = writeCharacteristic else { return }
            let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
            p.writeValue(data, for: c, type: type)
            ok = true
        }
        if ok { DiagnosticsLog.shared.frame("→", data) } else { DiagnosticsLog.shared.add("→ write refused: not connected") }
        return ok
    }

    /// The object handed to Rust. It holds the Bluetooth wrapper weakly so a stale
    /// session can never keep a dead link alive.
    private final class Link: RingLink {
        weak var owner: RingBluetooth?
        init(owner: RingBluetooth) { self.owner = owner }
        func write(data: Data) -> Bool { owner?.write(data) ?? false }
    }
}

extension RingBluetooth: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        diag.add("restored by iOS with \(restored.count) peripheral(s)")
        guard let p = restored.first else { return }
        peripheral = p
        p.delegate = self
        if p.state == .connected {
            p.discoverServices([Self.serviceUUID])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if case .poweredOff = state { state = .idle }
            if case .unauthorized = state { state = .idle }
            poweredOnWaiters.forEach { $0.resume() }
            poweredOnWaiters.removeAll()
        case .poweredOff:
            state = .poweredOff
            fail(BLEError.bluetoothUnavailable("Bluetooth is turned off"))
        case .unauthorized:
            state = .unauthorized
            poweredOnWaiters.forEach {
                $0.resume(throwing: BLEError.bluetoothUnavailable("Aurora is not allowed to use Bluetooth"))
            }
            poweredOnWaiters.removeAll()
        case .unsupported:
            state = .unsupported
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        // The charging case advertises too (different service, but be safe).
        guard !name.localizedCaseInsensitiveContains("case") else { return }
        guard connectContinuation != nil, peripheral == nil else { return }
        log.info("found \(name, privacy: .public) rssi \(RSSI.intValue)")
        diag.add("found \(name) rssi \(RSSI.intValue) id \(peripheral.identifier.uuidString)")
        connectTo(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        diag.add("didConnect \(peripheral.identifier.uuidString)")
        if self.peripheral == nil || self.peripheral?.identifier != peripheral.identifier {
            // The pending connect to the remembered ring won the race against the scan.
            central.stopScan()
            pendingRemembered = nil
            self.peripheral = peripheral
            peripheral.delegate = self
        }
        state = .connecting
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        diag.add("didFailToConnect \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "-")")
        if peripheral.identifier == pendingRemembered?.identifier, self.peripheral == nil {
            pendingRemembered = nil // keep scanning; the ring may show up under a new identifier
            return
        }
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        fail(BLEError.disconnected(error?.localizedDescription))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.info("disconnected: \(error?.localizedDescription ?? "-", privacy: .public)")
        diag.add("didDisconnect \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "-")")
        // Ignore links we already abandoned (e.g. the losing side of the scan race).
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        if connectContinuation != nil {
            fail(BLEError.disconnected(error?.localizedDescription))
        } else if wakePending {
            // The ring dropped during a scheduled wake before it was ready: re-arm it.
            reset()
            self.peripheral = peripheral
            central.connect(peripheral, options: [CBConnectPeripheralOptionStartDelayKey: 30])
            diag.add("wake re-armed in 30 s")
            state = .idle
        } else {
            reset()
            state = .idle
        }
    }
}

extension RingBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail(BLEError.missingCharacteristic)
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else {
            fail(BLEError.missingCharacteristic)
            return
        }
        writeCharacteristic = chars.first { $0.uuid == Self.writeUUID }
        guard writeCharacteristic != nil else {
            fail(BLEError.missingCharacteristic)
            return
        }
        // Ring 5 adds …0004/0005/0006; subscribing to all of them mirrors open_oura.
        diag.add("characteristics: " + chars.map { "\($0.uuid.uuidString.prefix(8)) \($0.properties.rawValue)" }.joined(separator: ", "))
        let notifying = chars.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        pendingNotifySubscriptions = notifying.count
        notifying.forEach { peripheral.setNotifyValue(true, for: $0) }
        finishIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log.error("notify \(characteristic.uuid): \(error.localizedDescription, privacy: .public)")
            diag.add("notify subscribe failed \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        }
        pendingNotifySubscriptions = max(0, pendingNotifySubscriptions - 1)
        finishIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        // History-event frames (tag >= 0x41) are thousands per sync: keep them out of the log.
        if value[value.startIndex] < 0x41 { diag.frame("← \(characteristic.uuid.uuidString.prefix(8))", value) }
        session?.pushNotification(data: value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log.error("write failed: \(error.localizedDescription, privacy: .public)")
            diag.add("write failed: \(error.localizedDescription)")
        }
    }
}
