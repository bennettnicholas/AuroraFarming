import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let day = model.selectedDay
        let summary = model.summary(for: day)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header(day: day)
                    if case .failed(let message) = model.syncPhase {
                        Card {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.amber)
                        }
                    }
                    SleepCard(summary: summary)
                    NightVitalsCard(summary: summary)
                    ActivityCard(summary: summary)
                    HeartRateDayCard(day: day)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .refreshable { await model.syncNow() }
            .auroraScreen()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private func header(day: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                VStack(spacing: 2) {
                    Text(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.wide)))
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text(day.formatted(.dateTime.month(.wide).day()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(Calendar.current.isDateInToday(day))
            }
            .font(.title3.weight(.semibold))
            HStack {
                Spacer()
                SyncPill()
                Spacer()
            }
        }
        .padding(.top, 8)
    }

    private func shift(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: model.selectedDay) {
            withAnimation(.snappy) { model.selectedDay = d }
        }
    }
}

private struct SleepCard: View {
    @Environment(AppModel.self) private var model
    let summary: DaySummary?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Last night", symbol: "moon.stars.fill")
                HStack(spacing: 20) {
                    let hours = summary?.asleepHours ?? summary?.timeInBedHours
                    RingGauge(progress: (hours ?? 0) / 8, tint: Theme.indigo, lineWidth: 14) {
                        VStack(spacing: 0) {
                            Text(hours.map { $0.hoursMinutes } ?? "–")
                                .font(.system(.headline, design: .rounded))
                            Text(summary?.asleepHours != nil ? "asleep" : "in bed")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 8) {
                        if let start = summary?.sleepStart, let end = summary?.sleepEnd {
                            Text("\(Date(timeIntervalSince1970: start).formatted(date: .omitted, time: .shortened)) – \(Date(timeIntervalSince1970: end).formatted(date: .omitted, time: .shortened))")
                                .font(.subheadline.weight(.medium))
                        } else {
                            Text("No sleep window detected yet")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        stage("Deep", summary?.deepHours, Theme.indigo)
                        stage("REM", summary?.remHours, Theme.violet)
                        stage("Light", summary?.lightHours, Theme.sky)
                        stage("Awake", summary?.awakeHours, Theme.amber)
                    }
                }
                if let start = summary?.sleepStart, let end = summary?.sleepEnd {
                    let stages = model.samples(.sleepStage, from: Date(timeIntervalSince1970: start - 3600),
                                               to: Date(timeIntervalSince1970: end + 3600))
                    if !stages.isEmpty { HypnogramChart(stages: stages) }
                }
            }
        }
    }

    @ViewBuilder
    private func stage(_ name: String, _ hours: Double?, _ color: Color) -> some View {
        if let hours {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(hours.hoursMinutes).font(.caption.monospacedDigit())
            }
        }
    }
}

private struct NightVitalsCard: View {
    let summary: DaySummary?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recovery signals", symbol: "sparkles")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    MetricTile(kind: .heartRate, value: summary?.restingHr, title: "Resting HR")
                    MetricTile(kind: .hrv, value: summary?.averageHrv, title: "HRV")
                    MetricTile(kind: .skinTemperature, value: summary?.temperatureDeviation ?? summary?.skinTemperature,
                               title: summary?.temperatureDeviation != nil ? "Temp. deviation" : "Skin temp.",
                               formatted: summary?.temperatureDeviation.map {
                                   String(format: Units.fahrenheit ? "%+.1f" : "%+.2f", MetricKind.skinTemperature.displayDelta($0))
                               })
                    MetricTile(kind: .respiratoryRate, value: summary?.respiratoryRate, title: "Breathing")
                    MetricTile(kind: .spo2, value: summary?.averageSpo2, title: "Blood oxygen")
                    MetricTile(kind: .battery, value: summary?.latestBattery, title: "Ring battery")
                }
            }
        }
    }
}

private struct ActivityCard: View {
    let summary: DaySummary?
    private let goalMinutes = 30.0

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Activity", symbol: "figure.walk.motion")
                HStack(spacing: 20) {
                    RingGauge(progress: Double(summary?.activeMinutes ?? 0) / goalMinutes, tint: Theme.lime,
                              lineWidth: 14) {
                        VStack(spacing: 0) {
                            Text("\(summary?.activeMinutes ?? 0)")
                                .font(.system(.title2, design: .rounded).weight(.semibold))
                            Text("active min").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 110, height: 110)
                    VStack(alignment: .leading, spacing: 10) {
                        stat("Active energy", "\(Int(summary?.activeKcal ?? 0)) kcal")
                        stat("Est. steps", (summary?.estimatedSteps ?? 0).formatted())
                        stat("MET-minutes", String(format: "%.0f", summary?.metMinutes ?? 0))
                    }
                }
                Text("Steps are estimated from movement intensity: the ring does not report a step count.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }
}

private struct HeartRateDayCard: View {
    @Environment(AppModel.self) private var model
    let day: Date

    var body: some View {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_400)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Heart rate", symbol: "heart.fill")
                    Spacer()
                    if let latest = model.latest(.heartRate) {
                        Text("\(Int(latest.value)) bpm · \(Date(timeIntervalSince1970: latest.ts).formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                // Every reading of the day; drag across the chart to read one.
                SampleChart(kind: .heartRate, samples: model.samples(.heartRate, from: start, to: end))
            }
        }
    }
}
