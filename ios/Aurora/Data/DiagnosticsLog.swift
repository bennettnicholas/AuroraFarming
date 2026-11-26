import Foundation

/// In-memory log of Bluetooth and sync events (last ~1500 lines) that the user can
/// copy from Settings and send when something fails on their ring. Never contains
/// the auth key: request frames are logged, and the only key-derived frame (the
/// auth response) is redacted.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 1500
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func add(_ message: String) {
        let line = "\(formatter.string(from: .now)) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    /// Hex of a frame, truncated, for the log.
    func frame(_ direction: String, _ data: Data) {
        var bytes = [UInt8](data)
        // 2f 11 2d <16 bytes>: the AES response to the auth nonce. Redact.
        if bytes.count >= 3, bytes[0] == 0x2f, bytes[2] == 0x2d { bytes = Array(bytes.prefix(3)) + [0] }
        let hex = bytes.prefix(48).map { String(format: "%02x", $0) }.joined()
        add("\(direction) \(hex)\(data.count > 48 ? "… (\(data.count)B)" : "")")
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); lines.removeAll(); lock.unlock()
    }
}
