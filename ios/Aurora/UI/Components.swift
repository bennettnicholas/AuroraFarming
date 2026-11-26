import Charts
import SwiftUI

/// Circular progress gauge with a gradient stroke.
struct RingGauge<Label: View>: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 12
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.6), tint], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.8), value: progress)
            label
        }
    }
}

/// A compact metric: icon, title, value and unit.
struct MetricTile: View {
    let kind: MetricKind
    let value: Double?
    var title: String? = nil
    var caption: String? = nil
    var formatted: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title ?? kind.title, systemImage: kind.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(kind.tint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(formatted ?? value.map(kind.format) ?? "–")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
                if value != nil || formatted != nil {
                    Text(kind.unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A min/max range + mean line chart over buckets.
struct BucketChart: View {
    let kind: MetricKind
    let buckets: [Bucket]
    var bucketSeconds: TimeInterval = 3600
    var height: CGFloat = 160

    var body: some View {
        if buckets.isEmpty {
            ContentUnavailableView("No \(kind.title.lowercased()) yet", systemImage: kind.symbol,
                                   description: Text(kind.emptyHint))
                .frame(height: height)
        } else {
            Chart(buckets, id: \.start) { b in
                let start = Date(timeIntervalSince1970: b.start)
                let mid = start.addingTimeInterval(bucketSeconds / 2)
                if b.max > b.min {
                    RectangleMark(
                        x: .value("Time", mid),
                        yStart: .value("Min", b.min),
                        yEnd: .value("Max", b.max),
                        width: .ratio(0.55)
                    )
                    .foregroundStyle(kind.tint.opacity(0.25))
                    .cornerRadius(4)
                }
                LineMark(x: .value("Time", mid), y: .value(kind.title, b.mean))
                    .foregroundStyle(kind.tint)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(x: .value("Time", mid), y: .value(kind.title, b.mean))
                    .foregroundStyle(kind.tint)
                    .symbolSize(18)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel()
                }
            }
            .frame(height: height)
        }
    }
}

/// Hypnogram for the ring's own sleep staging.
struct HypnogramChart: View {
    let stages: [Sample]

    private func label(_ code: Double) -> String {
        switch code {
        case 1: "Deep"
        case 2: "Light"
        case 3: "REM"
        default: "Awake"
        }
    }

    private func level(_ code: Double) -> Int {
        switch code {
        case 4: 3 // awake on top
        case 3: 2
        case 2: 1
        default: 0
        }
    }

    private func color(_ code: Double) -> Color {
        switch code {
        case 1: Theme.indigo
        case 2: Theme.sky
        case 3: Theme.violet
        default: Theme.amber
        }
    }

    var body: some View {
        Chart(stages, id: \.id) { s in
            RectangleMark(
                xStart: .value("Start", Date(timeIntervalSince1970: s.ts)),
                xEnd: .value("End", Date(timeIntervalSince1970: s.endTs ?? s.ts + 30)),
                yStart: .value("Stage", level(s.value)),
                yEnd: .value("Stage", level(s.value) + 1)
            )
            .foregroundStyle(color(s.value))
        }
        .chartYAxis {
            AxisMarks(values: [0, 1, 2, 3]) { v in
                AxisValueLabel {
                    if let i = v.as(Int.self) { Text(["Deep", "Light", "REM", "Awake"][i]).font(.caption2) }
                }
            }
        }
        .frame(height: 120)
    }
}

struct SectionHeader: View {
    let title: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(.white.opacity(0.9))
    }
}

extension Double {
    /// "7 h 32 m" for a number of hours.
    var hoursMinutes: String {
        let total = Int((self * 60).rounded())
        return "\(total / 60) h \(total % 60) m"
    }
}

/// Every recorded sample as a dot, joined by a thin line within continuous stretches
/// (a gap over `gapSeconds` breaks the line). Drag across it to read exact values.
struct SampleChart: View {
    let kind: MetricKind
    let samples: [Sample]
    var height: CGFloat = 160
    var gapSeconds: TimeInterval = 30 * 60

    @State private var selected: Date?

    private struct Point: Identifiable {
        let id: Int64
        let date: Date
        let value: Double
        let segment: Int
    }

    private var points: [Point] {
        var segment = 0
        var last: Double?
        return samples.map { s in
            if let last, s.ts - last > gapSeconds { segment += 1 }
            last = s.ts
            return Point(id: s.id, date: Date(timeIntervalSince1970: s.ts), value: s.value, segment: segment)
        }
    }

    private func nearest(to date: Date, in points: [Point]) -> Point? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    var body: some View {
        if samples.isEmpty {
            ContentUnavailableView("No \(kind.title.lowercased()) yet", systemImage: kind.symbol,
                                   description: Text(kind.emptyHint))
                .frame(height: height)
        } else {
            let points = self.points
            let pick = selected.flatMap { nearest(to: $0, in: points) }
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.date), y: .value(kind.title, p.value),
                             series: .value("Stretch", p.segment))
                        .foregroundStyle(kind.tint.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", p.date), y: .value(kind.title, p.value))
                        .foregroundStyle(kind.tint)
                        .symbolSize(points.count > 1500 ? 4 : 10)
                }
                if let pick {
                    RuleMark(x: .value("Selected", pick.date))
                        .foregroundStyle(.white.opacity(0.3))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(spacing: 2) {
                                Text("\(kind.format(pick.value)) \(kind.unit)").font(.caption.weight(.semibold))
                                Text(pick.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    PointMark(x: .value("Time", pick.date), y: .value(kind.title, pick.value))
                        .foregroundStyle(.white)
                        .symbolSize(40)
                }
            }
            .chartXSelection(value: $selected)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel()
                }
            }
            .frame(height: height)
        }
    }
}
