import SwiftUI

struct ConnectorsView: View {
    @Environment(ConnectorManager.self) private var manager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(manager.connectors, id: \.id) { c in
                        NavigationLink {
                            destination(for: c)
                        } label: {
                            ConnectorRow(connector: c, status: manager.statuses[c.id])
                        }
                        .disabled(!c.isAvailable)
                    }
                } footer: {
                    Text("Connectors send new readings after every sync. Each one keeps its own place, so nothing is sent twice and a failed upload is retried next time.")
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .auroraScreen()
            .navigationTitle("Share")
            .toolbar {
                Button {
                    Task { await manager.exportAll() }
                } label: {
                    if manager.isExporting { ProgressView() } else { Text("Send now") }
                }
                .disabled(manager.isExporting)
            }
        }
    }

    @ViewBuilder
    private func destination(for c: any HealthConnector) -> some View {
        if let nocturne = c as? NocturneConnector {
            NocturneSettingsView(connector: nocturne)
        } else {
            Text("\(c.displayName) is coming soon.")
        }
    }
}

private struct ConnectorRow: View {
    let connector: any HealthConnector
    let status: ConnectorStatus?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: connector.symbol)
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(Theme.aurora.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(connector.displayName).font(.headline)
                    if !connector.isAvailable {
                        Text("Soon").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.violet.opacity(0.3), in: Capsule())
                    } else if connector.isEnabled {
                        Circle().fill(Theme.mint).frame(width: 7, height: 7)
                    }
                }
                Text(connector.tagline).font(.caption).foregroundStyle(.secondary)
                if let status {
                    Text(status.error.map { "Error: \($0)" } ?? statusLine(status))
                        .font(.caption2)
                        .foregroundStyle(status.error == nil ? Color.secondary : Theme.amber)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct NocturneSettingsView: View {
    @Environment(ConnectorManager.self) private var manager
    @Bindable var connector: NocturneConnector
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Toggle("Send to Nocturne", isOn: $connector.isEnabled)
                    .disabled(!connector.isConfigured)
            }
            Section {
                TextField("https://yoursite.example", text: $connector.baseURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Access token (noc_…) or API secret", text: $connector.token)
            } header: {
                Text("Server")
            } footer: {
                Text("Create an access token in Nocturne with permission to write health data. A classic Nightscout API secret also works.")
            }
            Section {
                LabeledContent("Heart rate", value: "Always")
                Toggle("Estimated steps", isOn: $connector.exportSteps)
            } header: {
                Text("What to send")
            } footer: {
                Text("Steps are estimated from minute-by-minute movement intensity, not counted by the ring. Nocturne has no fields for HRV, temperature or SpO2 yet; those stay on your phone.")
            }
            Section {
                Button {
                    testing = true
                    Task {
                        do { testResult = try await connector.testConnection() } catch { testResult = userMessage(for: error) }
                        testing = false
                    }
                } label: {
                    HStack { Text("Test connection"); if testing { Spacer(); ProgressView() } }
                }
                .disabled(!connector.isConfigured || testing)
                if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                Button("Send everything again", role: .destructive) {
                    manager.resetCursor(for: connector)
                    Task { await manager.exportAll() }
                }
                .disabled(!connector.isConfigured)
            } footer: {
                Text("Re-sending is safe: Nocturne recognises records it already has.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackground())
        .navigationTitle("Nocturne")
    }
}

/// "Checked just now, nothing new · last sent 12 readings 4 min ago (newest 9:41 PM)".
private func statusLine(_ status: ConnectorStatus) -> String {
    var line = status.exported > 0
        ? "Sent \(status.exported) readings \(agoText(status.lastRun))"
        : "Checked \(agoText(status.lastRun)), nothing new"
    if status.exported == 0, let at = status.lastSentAt, let n = status.lastSentCount {
        line += " · last sent \(n) \(agoText(at))"
    }
    if let newest = status.newestSentReading {
        line += " · newest reading sent: \(newest.formatted(date: .omitted, time: .shortened))"
    }
    return line
}
