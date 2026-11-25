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
            case .timeout: return "The ring did not respond in time. Put it on its charger and try again."
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
    private var session: RingSession?

    private var poweredOnWaiters: [CheckedContinuation<Void, Error>] = []
    private var connectContinuation: CheckedContinuation<RingSession, Error>?

    /// Called on the main actor whenever the link state changes.
    var onStateChange: (@MainActor (State) -> Void)?
    private(set) var state: State = .idle {
        didSet {
            let s = state
            if let cb = onStateChange { Task { @MainActor in cb(s) } }
        }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
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
    func connect(timeout: TimeInterval = 25) async throws -> RingSession {
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
        if let previous = connectContinuation {
            previous.resume(throwing: CancellationError())
        }
        connectContinuation = cont
        // 1) The remembered ring, if iOS still knows it.
        if let id = rememberedPeripheral,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connectTo(known)
            return
        }
        // 2) A ring already connected to iOS (e.g. by another app).
        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            connectTo(connected)
            return
        }
        // 3) Scan.
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func connectTo(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: nil)
    }

    private func reset() {
        session = nil
        writeCharacteristic = nil
        pendingNotifySubscriptions = 0
        peripheral = nil
    }

    private func fail(_ error: Error) {
        central.stopScan()
        if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
        reset()
        state = .idle
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
    }

    private func finishIfReady() {
        guard let p = peripheral, writeCharacteristic != nil, pendingNotifySubscriptions == 0,
              session == nil else { return }
        let link = Link(owner: self)
        let s = RingSession(link: link)
        session = s
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.rememberedKey)
        state = .connected(name: p.name ?? "Oura Ring")
        log.info("ring ready: \(p.name ?? "?", privacy: .public)")
        connectContinuation?.resume(returning: s)
        connectContinuation = nil
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
        log.info("found \(name, privacy: .public) rssi \(RSSI.intValue)")
        connectTo(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(BLEError.disconnected(error?.localizedDescription))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.info("disconnected: \(error?.localizedDescription ?? "-", privacy: .public)")
        if connectContinuation != nil {
            fail(BLEError.disconnected(error?.localizedDescription))
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
        let notifying = chars.filter { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        pendingNotifySubscriptions = notifying.count
        notifying.forEach { peripheral.setNotifyValue(true, for: $0) }
        finishIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { log.error("notify \(characteristic.uuid): \(error.localizedDescription, privacy: .public)") }
        pendingNotifySubscriptions = max(0, pendingNotifySubscriptions - 1)
        finishIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        session?.pushNotification(data: value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log.error("write failed: \(error.localizedDescription, privacy: .public)") }
    }
}
