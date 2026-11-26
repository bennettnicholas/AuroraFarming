import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("profile.weightKg") private var weightKg: Double = 75
    @State private var stats: StoreStats?
    @State private var counts: [EventTypeCount] = []
    @State private var exportURL: URL?
    @State private var notice: String?
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section {
                Toggle("Sync every 5 minutes", isOn: Binding(
                    get: { model.continuousSync },
                    set: { model.continuousSync = $0 }))
            } header: {
                Text("Sync")
            } footer: {
                Text("Keeps Nocturne close to real time, also in the background. iOS reconnects to the ring every 5 minutes for a few seconds. Swiping Aurora away in the app switcher stops this until you open it again.")
            }
            Section("Profile") {
                Stepper(value: $weightKg, in: 30...200, step: 1) {
                    LabeledContent("Weight", value: "\(Int(weightKg)) kg")
                }
            }
            Section {
                if let stats {
                    LabeledContent("Ring events", value: stats.rawEvents.formatted())
                    LabeledContent("Decoded", value: stats.decodedEvents.formatted())
                    LabeledContent("Readings", value: stats.samples.formatted())
                    if let first = stats.firstSampleTs {
                        LabeledContent("Since", value: Date(timeIntervalSince1970: first).formatted(date: .abbreviated, time: .omitted))
                    }
                }
                NavigationLink("Event types") { EventCountsView(counts: counts) }
                Button("Re-process all data") {
                    do {
                        let n = try model.rebuildSamples()
                        notice = "Updated \(n) readings."
                        load()
                    } catch { notice = error.localizedDescription }
                }
                Button("Export database") {
                    do { exportURL = try model.exportDatabase() } catch { notice = error.localizedDescription }
                }
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Everything lives in one SQLite file on this iPhone. The export opens in open_oura's and open_health's desktop tools. It does not contain the ring key.")
            }
            if let notice { Section { Text(notice).font(.footnote) } }
            Section {
                Button("Forget this ring", role: .destructive) { confirmForget = true }
            } footer: {
                Text("Removes the ring key from this iPhone. Keep a copy first if the ring is not paired anywhere else: without the key the ring must be factory-reset to pair again.")
            }
            Section {
                NavigationLink("Bluetooth log") { DiagnosticsLogView() }
            } footer: {
                Text("If syncing or live heart rate misbehaves, open this right after it happens and share it. It never contains your ring key.")
            }
            Section("About") {
                LabeledContent("Core", value: coreVersion())
                Link("Protocol work: open_oura", destination: URL(string: "https://github.com/Th0rgal/open_oura")!)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground())
        .navigationTitle("Settings")
        .onAppear(perform: load)
        .confirmationDialog("Forget this ring?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget ring", role: .destructive) { model.forgetRing() }
        } message: {
            Text("Your synced data stays on this iPhone.")
        }
    }

    private func load() {
        stats = try? model.store.stats()
        counts = (try? model.store.eventCounts()) ?? []
    }
}

private struct EventCountsView: View {
    let counts: [EventTypeCount]
    var body: some View {
        List(counts, id: \.name) { c in
            LabeledContent(c.name) {
                Text("\(c.total.formatted()) · \(c.decoded.formatted()) decoded").font(.caption.monospacedDigit())
            }
        }
        .navigationTitle("Event types")
    }
}

private struct DiagnosticsLogView: View {
    @State private var text = DiagnosticsLog.shared.text

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Nothing logged yet." : text)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Bluetooth log")
        .toolbar {
            ToolbarItemGroup {
                Button("Copy") { UIPasteboard.general.string = text }
                ShareLink(item: text)
                Button("Clear") {
                    DiagnosticsLog.shared.clear()
                    text = ""
                }
            }
        }
        .onAppear { text = DiagnosticsLog.shared.text }
    }
}
