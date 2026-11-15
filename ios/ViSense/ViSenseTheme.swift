// ViSenseTheme.swift — dark glass UI, periwinkle accent, low-cost motion.
import SwiftUI

// MARK: - Palette

enum VSColor {
    static let canvas = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let canvasLift = Color(red: 0.09, green: 0.09, blue: 0.12)
    static let ink = Color.white
    static let inkMuted = Color.white.opacity(0.55)
    static let inkFaint = Color.white.opacity(0.32)
    static let accent = Color(red: 0.64, green: 0.58, blue: 1.0)
    static let accentSoft = Color(red: 0.64, green: 0.58, blue: 1.0).opacity(0.22)
    static let accentGlow = Color(red: 0.52, green: 0.45, blue: 0.92).opacity(0.45)
    static let live = Color(red: 0.45, green: 0.92, blue: 0.72)
    static let warn = Color(red: 1.0, green: 0.78, blue: 0.45)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.48)
}

enum VSMotion {
    static let reveal = Animation.spring(response: 0.48, dampingFraction: 0.84, blendDuration: 0)
    static let tap = Animation.spring(response: 0.28, dampingFraction: 0.9, blendDuration: 0)
    static func delay(_ index: Int) -> Double { min(0.32, 0.045 * Double(index)) }
}

// MARK: - Background (static — no continuous GPU animation)

struct AmbientBackground: View {
    var body: some View {
        ZStack {
            VSColor.canvas.ignoresSafeArea()
            RadialGradient(colors: [VSColor.accentGlow, .clear],
                           center: .init(x: 0.82, y: 0.08), startRadius: 0, endRadius: 280)
                .blendMode(.plusLighter)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(red: 0.35, green: 0.32, blue: 0.55).opacity(0.35), .clear],
                           center: .init(x: -0.1, y: 0.92), startRadius: 0, endRadius: 320)
                .ignoresSafeArea()
            Ellipse()
                .stroke(VSColor.accent.opacity(0.12), lineWidth: 1)
                .frame(width: 420, height: 120)
                .rotationEffect(.degrees(-18))
                .offset(x: 90, y: -220)
                .blur(radius: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Glass surfaces

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 20
    var stroke: Color = Color.white.opacity(0.14)

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(VSColor.canvasLift.opacity(0.55))
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
    }
}

extension View {
    func glass(radius: CGFloat = 20, stroke: Color = Color.white.opacity(0.14)) -> some View {
        modifier(GlassSurface(radius: radius, stroke: stroke))
    }
}

struct VSSelectedStroke: ViewModifier {
    var selected: Bool
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? VSColor.accent.opacity(0.85) : .clear, lineWidth: 1.5)
                .shadow(color: selected ? VSColor.accentGlow : .clear, radius: 14, y: 4)
        }
    }
}

// MARK: - Pop-in (Apple-style stagger, runs once)

struct VSReveal: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.94, anchor: .bottom)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                withAnimation(VSMotion.reveal.delay(VSMotion.delay(index))) { shown = true }
            }
    }
}

extension View {
    func vsReveal(_ index: Int = 0) -> some View {
        modifier(VSReveal(index: index))
    }
}

// MARK: - Buttons

struct VSPrimaryButtonStyle: ButtonStyle {
    var live: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(VSColor.canvas)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: live
                            ? [VSColor.danger, VSColor.danger.opacity(0.85)]
                            : [VSColor.accent, Color(red: 0.72, green: 0.65, blue: 1.0)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: (live ? VSColor.danger : VSColor.accent).opacity(configuration.isPressed ? 0.1 : 0.35),
                            radius: configuration.isPressed ? 6 : 18, y: 8)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(VSMotion.tap, value: configuration.isPressed)
    }
}

struct VSChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(VSColor.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glass(radius: 14, stroke: configuration.isPressed ? VSColor.accent.opacity(0.5) : Color.white.opacity(0.12))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(VSMotion.tap, value: configuration.isPressed)
    }
}

struct VSTabBar: View {
    @Binding var selection: AppNav.Tab

    private struct Item: Identifiable {
        let tab: AppNav.Tab
        let title: String
        let icon: String
        var id: AppNav.Tab { tab }
    }

    private let items: [Item] = [
        .init(tab: .captions, title: "Live", icon: "waveform"),
        .init(tab: .history, title: "Archive", icon: "tray.full"),
        .init(tab: .ask, title: "Recall", icon: "text.quote"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                Button {
                    withAnimation(VSMotion.tap) { selection = item.tab }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .symbolVariant(selection == item.tab ? .fill : .none)
                        Text(item.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(selection == item.tab ? VSColor.ink : VSColor.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        if selection == item.tab {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(VSColor.accentSoft)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .glass(radius: 22)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }

}

struct VSRootShell<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            AmbientBackground()
            content()
        }
    }
}

struct VSSectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(VSColor.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(VSColor.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VSConnectionPill: View {
    let connected: Bool
  @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? VSColor.live : VSColor.warn)
                .frame(width: 8, height: 8)
                .scaleEffect(connected && pulse ? 1.15 : 1)
                .animation(connected ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                           value: pulse)
            Text(connected ? "Glasses linked" : "Searching…")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(VSColor.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glass(radius: 20, stroke: connected ? VSColor.live.opacity(0.35) : VSColor.warn.opacity(0.35))
        .onAppear { pulse = true }
    }
}