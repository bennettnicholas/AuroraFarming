import SwiftUI

/// Aurora's visual language: deep night background, aurora-coloured accents,
/// frosted cards.
enum Theme {
    static let night = Color(red: 0.03, green: 0.05, blue: 0.10)
    static let nightRaised = Color(red: 0.07, green: 0.10, blue: 0.17)
    static let mint = Color(red: 0.36, green: 0.95, blue: 0.75)
    static let lime = Color(red: 0.66, green: 0.96, blue: 0.42)
    static let sky = Color(red: 0.38, green: 0.74, blue: 1.00)
    static let violet = Color(red: 0.65, green: 0.52, blue: 1.00)
    static let indigo = Color(red: 0.45, green: 0.47, blue: 1.00)
    static let rose = Color(red: 1.00, green: 0.42, blue: 0.55)
    static let amber = Color(red: 1.00, green: 0.73, blue: 0.36)

    static let aurora = LinearGradient(
        colors: [mint, sky, violet],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// The animated aurora backdrop used behind every screen.
struct AuroraBackground: View {
    @State private var phase = false

    var body: some View {
        ZStack {
            Theme.night
            Circle()
                .fill(Theme.mint.opacity(0.22))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: phase ? -120 : -60, y: phase ? -320 : -260)
            Circle()
                .fill(Theme.violet.opacity(0.22))
                .frame(width: 460, height: 460)
                .blur(radius: 140)
                .offset(x: phase ? 140 : 90, y: phase ? -180 : -240)
            Circle()
                .fill(Theme.sky.opacity(0.12))
                .frame(width: 380, height: 380)
                .blur(radius: 130)
                .offset(x: phase ? 40 : -20, y: phase ? 380 : 320)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) { phase.toggle() }
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
    }
}

extension View {
    func auroraScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(AuroraBackground())
    }
}
