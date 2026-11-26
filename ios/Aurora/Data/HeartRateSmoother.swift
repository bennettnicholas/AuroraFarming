import Foundation

/// Turns beat-to-beat intervals into a steady number for the live readout.
///
/// Each beat's own bpm swings by several bpm with breathing (that is heart-rate
/// variability, not sensor noise). Like a watch or the Oura app, show an average
/// over the last few seconds instead, and skip beats that are clearly artifacts
/// (a missed or doubled beat looks like a sudden ~2x or ~0.5x interval).
struct HeartRateSmoother {
    /// How far back the average reaches.
    var window: TimeInterval = 5
    /// A beat whose interval differs from the recent median by more than this is dropped.
    var outlierFraction: Double = 0.2

    private var beats: [(time: TimeInterval, ibi: Double)] = []

    /// Adds a beat and returns the smoothed bpm, or nil while there are too few beats.
    mutating func add(ibiMs: UInt16, at time: TimeInterval) -> UInt16? {
        let ibi = Double(ibiMs)
        beats.removeAll { time - $0.time > window }
        if beats.count >= 3 {
            let median = Self.median(beats.map(\.ibi))
            if abs(ibi - median) > median * outlierFraction { return current }
        }
        beats.append((time, ibi))
        return current
    }

    mutating func reset() { beats.removeAll() }

    /// Average bpm over the window: 60000 / mean interval (not the mean of per-beat bpm,
    /// which over-weights fast beats).
    var current: UInt16? {
        guard beats.count >= 2 else { return nil }
        let mean = beats.map(\.ibi).reduce(0, +) / Double(beats.count)
        return UInt16((60_000 / mean).rounded())
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
