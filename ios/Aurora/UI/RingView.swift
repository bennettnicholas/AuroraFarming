import SwiftUI

struct RingView: View {
    @Environment(AppModel.self) private var model
    @State private var features: [FeatureState] = []
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    liveCard
                    measurementsCard
                    if let notice {
                        Card { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .auroraScreen()
            .navigationTitle("Ring")
            .toolbar {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    let pct = Double(model.battery?.percent ?? UInt8(model.latest(.battery)?.value ?? 0))
                    RingGauge(progress: pct / 100, tint: pct < 20 ? Theme.rose : Theme.mint, lineWidth: 10) {
                        VStack(spacing: 0) {
                            Text(pct > 0 ? "\(Int(pct))%" : "–").font(.system(.headline, design: .rounded))
                            Image(systemName: "battery.75").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.ringInfo.map { $0.isRing5 ? "Oura Ring 5" : "Oura Ring" } ?? "Oura Ring")
                            .font(.title3.weight(.semibold))
                        Text(linkText).font(.caption).foregroundStyle(.secondary)
                        if let d = model.device {
                            Text("Firmware \(d.firmware) · \(d.hardwareId)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                SyncPill()
                if case .finished(let report) = model.syncPhase {
                    Text("Last sync: \(report.eventsReceived) events received, \(report.newEvents) new, \(report.samplesWritten) readings updated.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.amber)
                    }
                }
            }
        }
    }

    private var linkText: String {
        switch model.linkState {
        case .connected(let name): "Connected · \(name)"
        case .scanning: "Searching…"
        case .connecting: "Connecting…"
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth permission needed"
        case .unsupported: "Bluetooth unsupported"
        case .idle: model.lastSync.map { "Last synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet"
        }
    }

    private var liveCard: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "Live heart rate", symbol: "heart.fill")
                    Text("Streams beat-to-beat heart rate for a minute. Wear the ring.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isStreamingHeartRate {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(model.liveHeartRate.map { "\($0)" } ?? "…")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                            .foregroundStyle(Theme.rose)
                        Text("bpm").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await model.streamHeartRate() }
                    } label: {
                        Image(systemName: "play.fill").padding(10)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                }
            }
        }
    }

    private var measurementsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Measurements", symbol: "waveform")
                if features.isEmpty {
                    Text("Check which automatic measurements are on. After pairing a ring yourself, heart rate and SpO2 have to be switched on once.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(features, id: \.name) { f in
                    HStack {
                        Text(f.name).font(.subheadline)
                        Spacer()
                        Text(f.enabled ? f.mode.replacingOccurrences(of: "_", with: " ") : "off")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(f.enabled ? Theme.mint : Theme.amber)
                    }
                }
                HStack {
                    Button("Check") {
                        Task {
                            do { features = try await model.features() } catch { notice = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered)
                    Button("Turn on HR + SpO2") {
                        Task {
                            do {
                                let warnings = try await model.enableMeasurements()
                                notice = warnings.isEmpty ? "Automatic heart rate and SpO2 are on." : warnings.joined(separator: "\n")
                                features = try await model.features()
                            } catch { notice = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
