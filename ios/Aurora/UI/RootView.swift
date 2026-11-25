import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasKey {
            TabView {
                TodayView()
                    .tabItem { Label("Today", systemImage: "sun.horizon.fill") }
                TrendsView()
                    .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                RingView()
                    .tabItem { Label("Ring", systemImage: "circle.circle") }
                ConnectorsView()
                    .tabItem { Label("Share", systemImage: "arrow.up.forward.app") }
            }
        } else {
            OnboardingView()
        }
    }
}

/// Pill showing sync status; tapping it syncs.
struct SyncPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.syncNow() }
        } label: {
            HStack(spacing: 8) {
                if model.syncPhase.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon)
                }
                Text(text).lineLimit(1)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.syncPhase.isBusy)
    }

    private var icon: String {
        if case .failed = model.syncPhase { return "exclamationmark.triangle.fill" }
        return "arrow.triangle.2.circlepath"
    }

    private var text: String {
        switch model.syncPhase {
        case .connecting: return "Looking for your ring…"
        case .running(let stage, let events, let left):
            switch stage {
            case .authenticating: return "Unlocking ring…"
            case .preparingRing: return "Preparing…"
            case .downloading:
                let kb = Double(left) / 1024
                return left > 0 ? "Downloading · \(events) events · \(String(format: "%.0f", kb)) KB left"
                                : "Downloading · \(events) events"
            case .processing: return "Crunching numbers…"
            case .done: return "Done"
            }
        case .failed: return "Sync failed · tap to retry"
        case .finished, .idle:
            if let last = model.lastSync {
                return "Synced \(last.formatted(.relative(presentation: .named)))"
            }
            return "Sync now"
        }
    }
}
