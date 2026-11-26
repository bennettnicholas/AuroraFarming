import SwiftUI

/// First run: get an auth key for the ring.
///
/// The ring only shares health data with a phone that proves it knows the ring's
/// 16-byte key. A ring set up in the Oura app has a key only that app knows, so
/// there are two ways in: pair a factory-reset ring with a new key, or paste a key
/// you already have.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step = .welcome
    @State private var busy = false
    @State private var message: String?
    @State private var keyText = ""
    @State private var showWarnings: [String] = []

    enum Step { case welcome, checked(AppModel.RingCheck), enterKey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "circle.hexagongrid.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(Theme.aurora)
                    Text("Aurora")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("Your Oura Ring's data, straight to your phone. No account, no cloud.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                switch step {
                case .welcome: welcome
                case .checked(let check): checked(check)
                case .enterKey: enterKey
                }

                if let message {
                    Card { Label(message, systemImage: "info.circle").font(.footnote) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .auroraScreen()
        .disabled(busy)
        .overlay { if busy { ProgressView().controlSize(.large) } }
        .alert("Ring paired", isPresented: .constant(!showWarnings.isEmpty)) {
            Button("OK") { showWarnings = [] }
        } message: {
            Text(showWarnings.joined(separator: "\n"))
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("How it works", systemImage: "lock.shield").font(.headline)
                    Text("The ring only shares data with a phone that knows its secret key. Aurora talks to the ring over Bluetooth, keeps the key in your Keychain, and stores everything on this iPhone.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Button {
                run {
                    let check = try await model.checkRing()
                    step = .checked(check)
                }
            } label: {
                Label("Find my ring", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Tip: put the ring on its charger. It advertises more readily there.")
                .font(.caption).foregroundStyle(.secondary)
            Button("I already have my ring's key") { step = .enterKey }
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private func checked(_ check: AppModel.RingCheck) -> some View {
        switch check {
        case .ready(let info):
            ringCard(info, status: "Key accepted")
        case .factoryReset(let info):
            ringCard(info, status: "Factory-reset: ready to pair")
            Button {
                run { showWarnings = try await model.pairFactoryResetRing() + ["Measurements may take a few minutes to start."] }
            } label: {
                Label("Pair with Aurora", systemImage: "link").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .wrongKey(let info), .otherDevice(let info):
            ringCard(info, status: "Set up with another app")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("This ring belongs to the Oura app right now", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(Theme.amber)
                    Text("To use Aurora, either paste the ring's key (if you exported it), or factory-reset the ring and pair it here. A reset erases data that has not been synced yet and disconnects the ring from the Oura app, which would need to set it up again (and reset it again) to take it back.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Reset from the Oura app: Devices › your ring › Factory reset. Then tap Check again.")
                        .font(.subheadline)
                }
            }
            HStack {
                Button("Check again") {
                    run { step = .checked(try await model.checkRing()) }
                }
                .buttonStyle(.borderedProminent)
                Button("Enter key") { step = .enterKey }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func ringCard(_ info: RingInfo, status: String) -> some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "circle.circle.fill").font(.largeTitle).foregroundStyle(Theme.aurora)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.isRing5 ? "Oura Ring 5" : "Oura Ring").font(.headline)
                    Text("Firmware \(info.firmwareVersion) · \(info.hardwareId)").font(.caption).foregroundStyle(.secondary)
                    Text(status).font(.caption.weight(.semibold)).foregroundStyle(Theme.mint)
                }
            }
        }
    }

    private var enterKey: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ring auth key").font(.headline)
                    TextField("32 hex characters", text: $keyText, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("For example a key exported with open_oura's tools, or from a previous Aurora install. It is checked against the ring before it is saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                run {
                    if try await model.useExistingKey(keyText) == false {
                        message = "The ring rejected that key."
                    }
                }
            } label: {
                Text("Verify and save").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isValidAuthKey(hexKey: keyText))
            Button("Back") { step = .welcome }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        message = nil
        Task {
            do { try await work() } catch { message = userMessage(for: error) }
            busy = false
        }
    }
}
