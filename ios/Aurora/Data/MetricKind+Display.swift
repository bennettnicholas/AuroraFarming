import SwiftUI

extension MetricKind: CaseIterable, Identifiable {
    public static var allCases: [MetricKind] {
        [.heartRate, .hrv, .skinTemperature, .spo2, .respiratoryRate, .activityMet, .sleepSession, .sleepStage, .battery]
    }

    public var id: String { metricKindId(kind: self) }

    /// Kinds that make sense as a line/point chart.
    static var chartable: [MetricKind] {
        [.heartRate, .hrv, .skinTemperature, .spo2, .respiratoryRate, .activityMet, .battery]
    }

    var title: String {
        switch self {
        case .heartRate: "Heart rate"
        case .hrv: "HRV"
        case .skinTemperature: "Skin temperature"
        case .spo2: "Blood oxygen"
        case .respiratoryRate: "Breathing rate"
        case .activityMet: "Activity"
        case .sleepSession: "Sleep"
        case .sleepStage: "Sleep stages"
        case .battery: "Ring battery"
        }
    }

    var unit: String {
        if self == .skinTemperature && Units.fahrenheit { return "°F" }
        return metricKindUnit(kind: self)
    }

    /// A stored (metric) value in display units: only skin temperature changes.
    func display(_ value: Double) -> Double {
        self == .skinTemperature && Units.fahrenheit ? value * 9 / 5 + 32 : value
    }

    /// A difference (e.g. temperature deviation) in display units: no offset.
    func displayDelta(_ delta: Double) -> Double {
        self == .skinTemperature && Units.fahrenheit ? delta * 9 / 5 : delta
    }

    var symbol: String {
        switch self {
        case .heartRate: "heart.fill"
        case .hrv: "waveform.path.ecg"
        case .skinTemperature: "thermometer.medium"
        case .spo2: "drop.fill"
        case .respiratoryRate: "lungs.fill"
        case .activityMet: "figure.walk"
        case .sleepSession, .sleepStage: "moon.stars.fill"
        case .battery: "battery.75"
        }
    }

    var tint: Color {
        switch self {
        case .heartRate: Theme.rose
        case .hrv: Theme.violet
        case .skinTemperature: Theme.amber
        case .spo2: Theme.sky
        case .respiratoryRate: Theme.mint
        case .activityMet: Theme.lime
        case .sleepSession, .sleepStage: Theme.indigo
        case .battery: Theme.mint
        }
    }

    /// Formats a stored (metric) value in the user's display units.
    func format(_ value: Double) -> String {
        let value = display(value)
        return switch self {
        case .skinTemperature: String(format: Units.fahrenheit ? "%.1f" : "%.2f", value)
        case .spo2, .respiratoryRate, .activityMet: String(format: "%.1f", value)
        case .sleepSession: String(format: "%.1f", value)
        default: String(format: "%.0f", value)
        }
    }
}

extension MetricKind {
    /// What an empty chart tells the user: when this metric is expected to appear.
    var emptyHint: String {
        switch self {
        case .respiratoryRate: "Breathing rate is measured while you sleep. It appears after a night with the ring on."
        case .spo2: "Blood oxygen is measured while you sleep. It appears after a night with the ring on."
        case .sleepSession, .sleepStage: "Appears after a night with the ring on."
        case .skinTemperature: "Appears once the ring has been worn for a while and synced."
        case .hrv: "Mostly measured at night. Appears after a night with the ring on."
        default: "Sync your ring to fill this in."
        }
    }
}

/// Display units. Storage and uploads stay metric; only what's shown changes.
enum Units {
    static let fahrenheitKey = "units.fahrenheit"
    static let poundsKey = "units.pounds"
    /// Defaults to °F and lb.
    static var fahrenheit: Bool { UserDefaults.standard.object(forKey: fahrenheitKey) as? Bool ?? true }
    static var pounds: Bool { UserDefaults.standard.object(forKey: poundsKey) as? Bool ?? true }
    static let kgPerPound = 0.45359237
}
