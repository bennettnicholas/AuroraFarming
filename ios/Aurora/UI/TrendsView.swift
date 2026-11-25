import SwiftUI

enum TrendRange: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", quarter = "3 Months"
    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .quarter: 90 * 86_400
        }
    }

    var bucket: TimeInterval {
        switch self {
        case .day: 1800
        case .week: 6 * 3600
        case .month, .quarter: 86_400
        }
    }
}

struct TrendsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TrendRange = .week

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    let end = Date.now
                    let start = end.addingTimeInterval(-range.duration)
                    ForEach(MetricKind.chartable) { kind in
                        NavigationLink(value: kind) {
                            TrendCard(kind: kind,
                                      buckets: model.buckets(kind, from: start, to: end, bucket: range.bucket),
                                      bucketSeconds: range.bucket)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .auroraScreen()
            .navigationTitle("Trends")
            .navigationDestination(for: MetricKind.self) { MetricDetailView(kind: $0) }
        }
    }
}

private struct TrendCard: View {
    let kind: MetricKind
    let buckets: [Bucket]
    let bucketSeconds: TimeInterval

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(kind.title, systemImage: kind.symbol)
                        .font(.headline)
                        .foregroundStyle(kind.tint)
                    Spacer()
                    if !buckets.isEmpty {
                        let avg = buckets.map(\.mean).reduce(0, +) / Double(buckets.count)
                        Text("avg \(kind.format(avg)) \(kind.unit)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                BucketChart(kind: kind, buckets: buckets, bucketSeconds: bucketSeconds, height: 120)
            }
        }
    }
}

struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    let kind: MetricKind
    @State private var range: TrendRange = .day

    var body: some View {
        let end = Date.now
        let start = end.addingTimeInterval(-range.duration)
        let buckets = model.buckets(kind, from: start, to: end, bucket: range.bucket)
        let raw = model.samples(kind, from: start, to: end, limit: 20_000)
        ScrollView {
            VStack(spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(TrendRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Card {
                    BucketChart(kind: kind, buckets: buckets, bucketSeconds: range.bucket, height: 240)
                }
                Card {
                    let values = raw.map(\.value)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]) {
                        MetricTile(kind: kind, value: values.min(), title: "Low")
                        MetricTile(kind: kind, value: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                                   title: "Average")
                        MetricTile(kind: kind, value: values.max(), title: "High")
                    }
                    Text("\(raw.count.formatted()) readings")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                Card {
                    Text(explanation).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
        .auroraScreen()
        .navigationTitle(kind.title)
    }

    private var explanation: String {
        switch kind {
        case .heartRate: "5-minute averages from the ring's HRV records plus quality-gated beat-to-beat readings (Ring 5 green-LED stream)."
        case .hrv: "RMSSD, averaged over 5 minutes by the ring. Most meaningful during sleep."
        case .skinTemperature: "The ring's nocturnal skin-temperature stream. Look at changes from your own baseline, not absolute values."
        case .spo2: "Blood-oxygen readings the ring takes automatically, mostly at night."
        case .respiratoryRate: "Breaths per minute from the ring's sleep windows."
        case .activityMet: "Metabolic equivalent per minute: 1 is resting, 3+ is brisk walking, 7+ is running."
        case .battery: "Recorded each time the app syncs."
        case .sleepSession, .sleepStage: "Sleep windows and stages detected by the ring."
        }
    }
}
