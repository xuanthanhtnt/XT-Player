import SwiftUI

enum Theme {
    static let leaf = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)        // #34C759
    static let lime = Color(red: 0xA6 / 255, green: 0xE8 / 255, blue: 0x7A / 255)        // #A6E87A
    static let forest = Color(red: 0x11 / 255, green: 0x8A / 255, blue: 0x42 / 255)      // #118A42
    static let accent = Color(red: 0x2F / 255, green: 0xBF / 255, blue: 0x5B / 255)      // #2FBF5B
    static let danger = Color(red: 1.0, green: 0x45 / 255, blue: 0x3A / 255)             // #FF453A
    static let background = Color(red: 0x0E / 255, green: 0x12 / 255, blue: 0x10 / 255) // #0E1210

    static let brandGradient = LinearGradient(colors: [lime, leaf, forest], startPoint: .topLeading, endPoint: .bottomTrailing)

    #if os(tvOS)
    static let pagePadding: CGFloat = 80
    static let cardMinWidth: CGFloat = 420
    static let corner: CGFloat = 28
    static let posterWidth: CGFloat = 250
    static let landscapeWidth: CGFloat = 440
    #else
    static let pagePadding: CGFloat = 24
    static let cardMinWidth: CGFloat = 280
    static let corner: CGFloat = 20
    static let posterWidth: CGFloat = 140
    static let landscapeWidth: CGFloat = 280
    #endif
}

/// Deep matte black-green with a faint leaf glow — the backdrop for every screen.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.leaf.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Theme.forest.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 640)
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

extension View {
    /// The Mac window uses a hidden title bar (video and artwork reach the top edge), so page titles are
    /// drawn in the content as large Infuse-style headings there; elsewhere it is a normal navigation title.
    @ViewBuilder
    func pageTitle(_ title: String) -> some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 10)
                .padding(.bottom, 4)
            self
        }
        .navigationTitle(title)
        #else
        navigationTitle(title)
        #endif
    }
}
