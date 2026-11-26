import SwiftUI

/// Pick a watch that broadcasts heart rate, and see whether it's sending.
struct WatchSetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let watch = model.watch
        List {
            Section {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(watch.deviceName ?? "No watch chosen").font(.headline)
                        Text(statusText(watch)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if watch.deviceName != nil {
                    Button("Forget this watch", role: .destructive) { watch.forget() }
                }
            }
            Section {
                Button(watch.isScanning ? "Searching…" : "Find my watch") { watch.startScan() }
                    .disabled(watch.isScanning)
                ForEach(watch.found) { f in
                    Button {
                        watch.choose(f.id)
                    } label: {
                        HStack {
                            Text(f.name)
                            Spacer()
                            if f.rssi != 0 { Text("\(f.rssi) dBm").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } footer: {
                Text("Start heart-rate broadcast on the watch first, then search. Only devices broadcasting heart rate show up.")
            }
            Section("Garmin Enduro 3 setup") {
                Text("1. Hold the LIGHT button to open the controls menu.\n2. Choose Broadcast Heart Rate (add it with Edit Controls if it's missing).\n3. In Aurora, tap Find my watch and pick the Enduro.\n\nTo broadcast automatically during recorded activities as well, turn on Broadcast During Activity under the watch's wrist heart rate settings. Broadcasting uses extra watch battery.")
                    .font(.footnote)
            }
            Section {
                Text("While the watch is sending heart rate, the exercise reminder follows it second by second instead of the ring's 5-minute syncs. When it stops, the ring takes over again. Aurora reconnects by itself when the broadcast comes back.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground())
        .navigationTitle("Heart-rate watch")
        .onDisappear { watch.stopScan() }
    }

    private func statusText(_ watch: HeartRateMonitor) -> String {
        switch watch.status {
        case .off: return "Bluetooth is off."
        case .notChosen: return "Choose a watch below."
        case .waiting: return "Waiting for the watch to broadcast heart rate."
        case .connected:
            if let bpm = watch.latestBPM, let at = watch.latestAt {
                return watch.isLive ? "Receiving: \(bpm) bpm" : "Connected, last reading \(agoText(at))"
            }
            return "Connected, waiting for the first reading."
        }
    }
}
