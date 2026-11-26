import CoreBluetooth
import Foundation
import Observation

/// A watch or strap that broadcasts the standard Bluetooth Heart Rate Service
/// (0x180D), e.g. a Garmin with "Broadcast Heart Rate" on. Gives second-by-second
/// heart rate for the exercise reminder, also in the background.
///
/// Once a device is chosen it is remembered, and a connection request is kept
/// pending whenever it is out of reach: iOS completes it as soon as the watch
/// broadcasts again (also with Aurora in the background, and after iOS relaunches
/// Aurora through state restoration).
@MainActor
@Observable
final class HeartRateMonitor: NSObject {
    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    enum Status: Equatable {
        case off, notChosen, waiting, connected
    }

    static let service = CBUUID(string: "180D")
    static let measurement = CBUUID(string: "2A37")
    private static let rememberedKey = "hrm.peripheral"
    private static let nameKey = "hrm.name"

    private(set) var status: Status = .off
    private(set) var found: [Found] = []
    private(set) var isScanning = false
    private(set) var latestBPM: Int?
    private(set) var latestAt: Date?
    var deviceName: String? { UserDefaults.standard.string(forKey: Self.nameKey) }

    /// Called for every reading (bpm, time).
    @ObservationIgnored var onReading: ((Int, Date) -> Void)?

    /// The last 15 minutes of readings, oldest first.
    @ObservationIgnored private(set) var recent: [(date: Date, bpm: Int)] = []

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var discovered: [UUID: CBPeripheral] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.aurorafarming.aurora.hrm",
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    private var remembered: UUID? {
        UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:))
    }

    /// True when the watch sent a reading in the last 2 minutes.
    var isLive: Bool { latestAt.map { Date.now.timeIntervalSince($0) < 120 } ?? false }

    func startScan() {
        guard central.state == .poweredOn else { return }
        found = []
        isScanning = true
        central.scanForPeripherals(withServices: [Self.service], options: nil)
        // Devices already connected to iOS (e.g. by another app) don't advertise.
        for p in central.retrieveConnectedPeripherals(withServices: [Self.service]) {
            discovered[p.identifier] = p
            found.append(Found(id: p.identifier, name: p.name ?? "Heart-rate monitor", rssi: 0))
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.stopScan()
        }
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    func choose(_ id: UUID) {
        stopScan()
        guard let p = discovered[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        if let old = peripheral, old.identifier != id { central.cancelPeripheralConnection(old) }
        UserDefaults.standard.set(id.uuidString, forKey: Self.rememberedKey)
        UserDefaults.standard.set(p.name ?? "Heart-rate monitor", forKey: Self.nameKey)
        connect(p)
    }

    func forget() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        latestBPM = nil
        latestAt = nil
        recent = []
        status = .notChosen
    }

    /// Per-minute median heart rate over the last `minutes`, newest last; nil where the
    /// watch sent nothing that minute.
    func minuteMedians(_ minutes: Int, now: Date = .now) -> [Double?] {
        let from = now.addingTimeInterval(-Double(minutes) * 60)
        var buckets = Array(repeating: [Int](), count: minutes)
        for r in recent where r.date >= from && r.date <= now {
            let i = min(minutes - 1, Int(r.date.timeIntervalSince(from) / 60))
            buckets[i].append(r.bpm)
        }
        return buckets.map { b in
            guard !b.isEmpty else { return nil }
            let s = b.sorted()
            return Double(s[s.count / 2])
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        status = .waiting
        // No timeout: iOS keeps this pending until the watch is in range and broadcasting.
        central.connect(p, options: nil)
    }

    private func reconnectRemembered() {
        guard central.state == .poweredOn else { status = .off; return }
        guard let id = remembered else { status = .notChosen; return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first { connect(p) }
    }

    fileprivate func handle(_ data: Data) {
        guard let bpm = Self.parse(data) else { return }
        let now = Date.now
        latestBPM = bpm
        latestAt = now
        recent.append((now, bpm))
        let cutoff = now.addingTimeInterval(-15 * 60)
        if let first = recent.first, first.date < cutoff { recent.removeAll { $0.date < cutoff } }
        onReading?(bpm, now)
    }

    /// Heart Rate Measurement (0x2A37): flags bit 0 picks a UInt8 or UInt16 LE value.
    /// A sensor that reports "not in contact" (bits 1-2 = 0b10) is ignored.
    nonisolated static func parse(_ data: Data) -> Int? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let flags = b[0]
        if (flags >> 1) & 0b11 == 0b10 { return nil } // contact supported, not detected
        let bpm = flags & 1 == 0 ? Int(b[1]) : (b.count >= 3 ? Int(b[1]) | Int(b[2]) << 8 : 0)
        return (25...240).contains(bpm) ? bpm : nil
    }
}

extension HeartRateMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { reconnectRemembered() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
                peripheral = p
                p.delegate = self
                if p.state == .connected { p.discoverServices([Self.service]) }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            discovered[peripheral.identifier] = peripheral
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Heart-rate monitor"
            if let i = found.firstIndex(where: { $0.id == peripheral.identifier }) {
                found[i].rssi = RSSI.intValue
            } else {
                found.append(Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            DiagnosticsLog.shared.add("watch HR: connected \(peripheral.name ?? "?")")
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral.identifier == remembered else { return }
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            DiagnosticsLog.shared.add("watch HR: disconnected (\(error?.localizedDescription ?? "-"))")
            // Broadcast off or out of range: wait for it to come back.
            guard peripheral.identifier == remembered else { return }
            connect(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return }
            peripheral.discoverCharacteristics([Self.measurement], for: s)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let c = service.characteristics?.first(where: { $0.uuid == Self.measurement }) else { return }
            peripheral.setNotifyValue(true, for: c)
            status = .connected
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.measurement, let data = characteristic.value else { return }
        MainActor.assumeIsolated { handle(data) }
    }
}
