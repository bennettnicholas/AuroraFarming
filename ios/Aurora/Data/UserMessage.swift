import Foundation

/// A readable message for an error shown in the UI, instead of
/// "The operation couldn't be completed. (… error 1.)" or the generated
/// `CoreError` description (UniFFI's is `String(reflecting:)`).
func userMessage(for error: Error) -> String {
    if error is CancellationError {
        return "The ring was busy with another request. Try again."
    }
    if let core = error as? CoreError {
        switch core {
        case .Link(let message): return "Lost the connection to the ring (\(message)). Try again."
        case .Auth(let message): return message
        case .Ring(let message): return "The ring didn't answer as expected (\(message)). Try again."
        case .Store(let message): return "Aurora's database had a problem: \(message)."
        case .InvalidKey: return "The auth key must be 32 hex characters (16 bytes)."
        }
    }
    return error.localizedDescription
}
