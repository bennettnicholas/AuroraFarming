import SwiftUI

/// Every recent sync with what started it, so the background cadence can be checked.
struct SyncHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        List {
            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.continuousSync {
                            Text("5-minute sync is off.")
                        } else if let next = history.nextWakeAt, next > context.date.addingTimeInterval(-60) {
                            Text("Next background sync around \(next.formatted(date: .omitted, time: .shortened))")
                        } else if let next = history.nextWakeAt {
                            Text("A background sync was due at \(next.formatted(date: .omitted, time: .shortened)). It runs once the ring is in range and iOS lets it.")
                        } else {
                            Text("Background syncs start once you leave the app.")
                        }
                        let bg = history.records.prefix(50).filter(\.wasInBackground)
                        if bg.count >= 2 {
                            let gaps = zip(bg, bg.dropFirst()).map { $0.date.timeIntervalSince($1.date) }
                            let median = gaps.sorted()[gaps.count / 2]
                            Text("Typical gap between background syncs: \(Int((median / 60).rounded())) min")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                }
            }
            Section {
                if history.records.isEmpty {
                    Text("No syncs recorded yet.").foregroundStyle(.secondary)
                }
                ForEach(history.records) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(r.ok ? Theme.mint : Theme.amber)
                            Text(r.date.formatted(date: .abbreviated, time: .standard))
                                .font(.subheadline.monospacedDigit())
                            Spacer()
                            Text(r.wasInBackground ? "background" : "app open")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((r.wasInBackground ? Theme.violet : Theme.sky).opacity(0.3), in: Capsule())
                        }
                        Text("\(r.trigger.rawValue) · \(r.detail)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let e = r.exercise {
                            Text(e).font(.caption).foregroundStyle(e.contains("started") ? Theme.rose : .secondary)
                        }
                        if let n = r.nocturne {
                            Text(n).font(.caption).foregroundStyle(n.contains("failed") ? Theme.amber : .secondary)
                        }
                    }
                }
            } footer: {
                Text("Background syncs happen when iOS reconnects to the ring, about every 5 minutes. They pause while the ring is out of range, Bluetooth is off, or after Aurora is swiped away.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground())
        .navigationTitle("Sync history")
        .toolbar {
            Button("Clear") { history.clear() }
        }
    }
}
