import SwiftUI

enum Theme {
    static let red = Color(red: 1.0, green: 0x3B / 255, blue: 0x30 / 255)        // #FF3B30
    static let orange = Color(red: 1.0, green: 0x95 / 255, blue: 0.0)             // #FF9500
    static let accent = Color(red: 1.0, green: 0x5E / 255, blue: 0x1F / 255)      // #FF5E1F
    static let background = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255) // #121212

    static let brandGradient = LinearGradient(colors: [red, orange], startPoint: .leading, endPoint: .trailing)

    #if os(tvOS)
    static let pagePadding: CGFloat = 80
    static let cardMinWidth: CGFloat = 420
    static let corner: CGFloat = 28
    #else
    static let pagePadding: CGFloat = 24
    static let cardMinWidth: CGFloat = 280
    static let corner: CGFloat = 20
    #endif
}

/// Deep matte black with a faint ember glow — the backdrop for every screen.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.red.opacity(0.20), .clear], center: .topLeading, startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Theme.orange.opacity(0.08), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 640)
        }
        .ignoresSafeArea()
    }
}

/// Frosted-glass panel used for cards and player chrome.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = Theme.corner

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = Theme.corner) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

/// Small capsule tag ("4K", "Dolby Vision", "TrueHD 7.1").
struct TagChip: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(highlighted ? Color.black : Color.white.opacity(0.9))
            .background(
                Capsule().fill(highlighted ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.white.opacity(0.12)))
            )
    }
}

/// Plain button style that keeps tvOS focus but draws nothing extra.
struct InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
