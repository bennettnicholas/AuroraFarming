import Foundation

/// Placeholder for a Trio (open-source iOS automated insulin delivery) connector.
///
/// Trio has no plug-in API for third-party data today, so there are three ways in,
/// listed in `docs/CONNECTORS.md`:
/// 1. Through Nightscout/Nocturne, which Trio already talks to. With the Nocturne
///    connector on, the data is already where Trio-adjacent tooling can read it.
/// 2. Through Apple Health (an `AppleHealthConnector` writing heart rate, HRV and
///    sleep), if Trio starts reading those types.
/// 3. A small change in Trio itself (e.g. heart rate / activity as a sensitivity
///    input), fed by an App Group or URL scheme from Aurora.
///
/// The data layer already supports all three: this class only needs `upload(_:)`.
@MainActor
@Observable
final class TrioConnector: HealthConnector {
    let id = "trio"
    let displayName = "Trio"
    let tagline = "Activity and heart rate for automated insulin delivery (planned)"
    let symbol = "syringe.fill"
    let isAvailable = false
    var isEnabled = false
    var exportedKinds: [MetricKind] { [.heartRate, .hrv, .activityMet, .sleepSession] }
    var isConfigured: Bool { false }

    func upload(_ samples: [Sample]) async throws {}

    func testConnection() async throws -> String {
        "The Trio connector is not available yet."
    }
}
