import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("profile.weightKg") private var weightKg: Double = 75
    @AppStorage(Units.fahrenheitKey) private var fahrenheit = true
    @AppStorage(Units.poundsKey) private var pounds = true
    @AppStorage(ExerciseAlerts.Key.enabled) private var exerciseOn = false
    @AppStorage(ExerciseAlerts.Key.hr) private var exerciseHR = 120.0
    @AppStorage(ExerciseAlerts.Key.met) private var exerciseMET = 5.0
    @AppStorage(ExerciseAlerts.Key.hrOnly) private var exerciseHROnly = false
    @AppStorage(ExerciseAlerts.Key.minutes) private var exerciseMinutes = 5
    @AppStorage(ExerciseAlerts.Key.endNotice) private var exerciseEndNotice = true
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
                NavigationLink("Sync history") { SyncHistoryView() }
            } header: {
                Text("Sync")
            } footer: {
                Text("Keeps Nocturne close to real time, also in the background. iOS reconnects to the ring every 5 minutes for a few seconds. Swiping Aurora away in the app switcher stops this until you open it again.")
            }
            Section {
                Toggle("Exercise reminder", isOn: $exerciseOn)
                    .onChange(of: exerciseOn) { _, on in
                        guard on else { return }
                        Task {
                            if !(await ExerciseAlerts.requestPermission()) {
                                notice = "Allow notifications for Aurora in iOS Settings so the reminder can appear."
                            }
                            // Lets the ring measure heart rate continuously during workouts.
                            _ = try? await model.enableMeasurements()
                        }
                    }
                if exerciseOn {
                    Stepper(value: $exerciseHR, in: 80...200, step: 5) {
                        LabeledContent("Heart rate at or above", value: "\(Int(exerciseHR)) bpm")
                    }
                    Toggle("Heart rate only (ignore movement)", isOn: $exerciseHROnly)
                    if !exerciseHROnly {
                        Stepper(value: $exerciseMET, in: 3...10, step: 0.5) {
                            LabeledContent("Or movement at or above", value: String(format: "%.1f MET", exerciseMET))
                        }
                    }
                    Stepper(value: $exerciseMinutes, in: 2...8) {
                        LabeledContent("Active minutes needed", value: "\(exerciseMinutes) of last 8")
                    }
                    Toggle("Also tell me when it ends", isOn: $exerciseEndNotice)
                    Button("Send a test notification") { ExerciseAlerts.sendTest() }
                }
            } header: {
                Text("Exercise")
            } footer: {
                Text("After each sync (about every 5 minutes), Aurora checks the last 8 minutes and reminds you to set a temp target in Trio when you've been active for most of them. A flight of stairs won't count. It's only a reminder: nothing is changed in Trio. Your iPhone has to be within Bluetooth range of the ring, so keep it on the bench, not in the locker room. Each decision shows in Sync history.")
            }
            Section("Profile") {
                if pounds {
                    // Stored in kg; stepped in whole pounds.
                    Stepper(value: Binding(get: { (weightKg / Units.kgPerPound).rounded() },
                                           set: { weightKg = $0 * Units.kgPerPound }),
                            in: 66...440, step: 1) {
                        LabeledContent("Weight", value: "\(Int((weightKg / Units.kgPerPound).rounded())) lb")
                    }
                } else {
                    Stepper(value: $weightKg, in: 30...200, step: 1) {
                        LabeledContent("Weight", value: "\(Int(weightKg.rounded())) kg")
                    }
                }
                Picker("Temperature", selection: $fahrenheit) {
                    Text("°F").tag(true)
                    Text("°C").tag(false)
                }
                Picker("Weight unit", selection: $pounds) {
                    Text("lb").tag(true)
                    Text("kg").tag(false)
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
                    } catch { notice = userMessage(for: error) }
                }
                Button("Export database") {
                    do { exportURL = try model.exportDatabase() } catch { notice = userMessage(for: error) }
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
