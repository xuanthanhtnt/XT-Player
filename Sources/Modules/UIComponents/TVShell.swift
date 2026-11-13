import SwiftUI

#if os(tvOS)
/// Apple TV navigation. The menu is hidden and the page fills the screen; pressing left at the page's left edge
/// (or Menu at the top of a page) brings the menu in from the left, on the section being shown, and shrinks the
/// page to make room. Right, or picking a section, puts the page back. "Cài đặt" opens a second level in the menu itself: its groups, and the
/// group under the focus shown in a panel beside the menu (no Settings page).
struct TVShell: View {
    @Binding var section: AppSection
    /// Navigation inside each section, kept while another one is shown.
    @State private var paths: [AppSection: [Route]] = [:]
    @FocusState private var focused: RailFocus?
    @State private var menuOpen = false
    @State private var settingsOpen = false
    @State private var settingsGroup: SettingsGroup?
    /// When the page's focus last moved: a left press that moved nothing was at the page's left edge.
    @State private var lastPageFocusMove = Date.distantPast
    /// The invisible strip along the left edge that opens the menu when the focus reaches it.
    @FocusState private var edgeFocused: Bool
    /// Off at launch and for a moment after the menu closes or the page changes, while the focus settles in
    /// the page (the strip is the screen's top-left-most focusable and would take it).
    @State private var edgeEnabled = false

    enum RailFocus: Hashable {
        case section(AppSection)
        case settings
        case group(SettingsGroup)
    }

    struct Item: Identifiable {
        let section: AppSection
        let title: String
        let icon: String
        var id: AppSection { section }
    }

    static let items: [Item] = [
        Item(section: .home, title: "Trang chủ", icon: "house.fill"),
        Item(section: .movies, title: "Phim", icon: "film.fill"),
        Item(section: .shows, title: "TV Shows", icon: "tv.fill"),
        Item(section: .music, title: "Nhạc", icon: "music.note"),
        Item(section: .musicVideos, title: "Video ca nhạc", icon: "music.note.tv.fill"),
        Item(section: .sources, title: "Nguồn", icon: "externaldrive.connected.to.line.below.fill"),
    ]

    static let menuWidth: CGFloat = 400
    static let panelWidth: CGFloat = 760

    var body: some View {
        GeometryReader { geo in
            // The page, scaled from its trailing edge, ends up just right of the open menu.
            let shrink = (geo.size.width - Self.menuWidth - 30) / geo.size.width
            ZStack(alignment: .leading) {
                AppBackground()
                page
                    .disabled(menuOpen)
                    .onMoveCommand { direction in
                        guard direction == .left, !menuOpen else { return }
                        let pressed = Date()
                        // Closed, the menu cannot take the focus (up from the top of a page went into it): a left
                        // press after which the page's focus has not moved opens it instead.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            if lastPageFocusMove < pressed, !menuOpen { openMenu() }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { _ in
                        if !menuOpen { lastPageFocusMove = Date() }
                    }
                    // Behind the settings panel the page steps further back.
                    .blur(radius: settingsGroup != nil ? 14 : 0)
                    .brightness(settingsGroup != nil ? -0.4 : menuOpen ? -0.2 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: menuOpen ? 40 : 0, style: .continuous))
                    .scaleEffect(menuOpen ? shrink : 1, anchor: .trailing)
                    .shadow(color: .black.opacity(menuOpen ? 0.6 : 0), radius: 50, x: -16)
                if !menuOpen {
                    edgeStrip
                }
                if settingsOpen, let group = settingsGroup {
                    settingsPanel(group)
                        .padding(.leading, Self.menuWidth + 20)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }
                if menuOpen {
                    menu
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(2)
                }
            }
        }
        .ignoresSafeArea()
        .task { await enableEdge(after: 1.0) }
        .onChange(of: edgeFocused) { _, focused in
            if focused { openMenu() }
        }
        .onChange(of: paths) { _, _ in
            // A page pushed or popped: its first focus must land in it, not on the strip.
            edgeEnabled = false
            Task { await enableEdge(after: 0.7) }
        }
        .environment(\.dynamicTypeSize, .xSmall)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: menuOpen)
        .animation(.spring(response: 0.36, dampingFraction: 0.9), value: settingsOpen)
        .animation(.easeInOut(duration: 0.2), value: settingsGroup)
        .onChange(of: focused) { _, new in
            switch new {
            case let .section(target)?:
                menuOpen = true
                // As in Apple's own apps, the section under the focus is shown while moving through the menu.
                if target != section { section = target }
                settingsOpen = false
                settingsGroup = nil
            case .settings?:
                menuOpen = true
                settingsGroup = nil
            case let .group(group)?:
                menuOpen = true
                settingsGroup = group
            case nil:
                // Into the settings panel (the menu stays), or to the page once the menu was closed.
                break
            }
        }
        // Menu at the top of a page opens the menu; inside a page it goes back (the stack handles it).
        .onExitCommand(perform: menuOpen || !(paths[section] ?? []).isEmpty ? nil : { openMenu() })
    }

    // MARK: Page

    private var page: some View {
        NavigationStack(path: Binding(get: { paths[section] ?? [] }, set: { paths[section] = $0 })) {
            root(section).libraryRoutes()
        }
        .id(section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func root(_ section: AppSection) -> some View {
        switch section {
        case .movies: LibraryGridView(kind: .movie)
        case .shows: LibraryGridView(kind: .show)
        case .music: MusicLibraryView()
        case .musicVideos: MusicVideosView()
        case .sources: SourcesView()
        case .settings: SettingsView()
        default: HomeView()
        }
    }

    // MARK: Menu

    private var menu: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.brandGradient)
                    Text("XT Player").font(.title3.weight(.heavy))
                }
                .padding(.leading, 14)
                .padding(.bottom, 30)
                ForEach(Self.items) { item in
                    row(title: item.title, icon: item.icon, selected: section == item.section, focus: .section(item.section)) {
                        closeMenu()
                    }
                }
                row(title: "Cài đặt", icon: "gearshape.fill", selected: settingsOpen, focus: .settings,
                    trailing: settingsOpen ? "chevron.down" : "chevron.right") {
                    settingsOpen.toggle()
                    if !settingsOpen { settingsGroup = nil }
                }
                .padding(.top, 18)
                if settingsOpen {
                    ForEach(SettingsGroup.allCases) { group in
                        row(title: group.title, icon: group.icon, selected: settingsGroup == group, focus: .group(group),
                            indent: true, trailing: "chevron.right") {
                            // The panel beside the menu takes the remote (moving right does the same).
                            settingsGroup = group
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 64)
        }
        .frame(width: Self.menuWidth)
        .frame(maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Theme.background.opacity(0.6))
                .ignoresSafeArea()
        }
        .focusSection()
        .onMoveCommand { direction in
            // Right from a section closes the menu; from the settings groups it goes into their panel.
            guard direction == .right, menuOpen else { return }
            if case .group = focused { return }
            closeMenu()
        }
        .onExitCommand(perform: settingsOpen ? {
            settingsOpen = false
            settingsGroup = nil
            focused = .settings
        } : nil)
        .environment(\.colorScheme, .dark)
    }

    private func row(title: String, icon: String, selected: Bool, focus: RailFocus, indent: Bool = false,
                     trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MenuRowLabel(title: title, icon: icon, selected: selected, indent: indent, trailing: trailing)
        }
        .buttonStyle(MenuRowStyle())
        .focused($focused, equals: focus)

    }

    // MARK: Settings panel

    private func settingsPanel(_ group: SettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(group.title, systemImage: group.icon)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 30)
            Group {
                if group == .diagnostics {
                    DiagnosticsLogView()
                } else {
                    SettingsView(only: group)
                }
            }
            .padding(.horizontal, 26)
            .id(group)
        }
        .padding(.vertical, 50)
        .frame(width: Self.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        .padding(.vertical, 40)
        .focusSection()
        // Back from the panel returns to its group in the menu.
        .onExitCommand { focused = .group(group) }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Opening and closing

    private func openMenu() {
        menuOpen = true
        // On the section being shown (the focus engine picked the row nearest the page's focus, often Settings);
        // the rows are enabled in this update, so the focus is set on the next turn.
        DispatchQueue.main.async { focused = .section(section) }
    }

    /// Closes the menu and hands the focus to the page: the menu leaves the screen, so the focus engine moves to
    /// the (now enabled) page.
    private func closeMenu() {
        menuOpen = false
        settingsOpen = false
        settingsGroup = nil
        edgeEnabled = false
        Task { await enableEdge(after: 0.7) }
    }

    /// Full height and only a few points wide: nothing is above or below it, so up and down never reach it; left
    /// from the page's leftmost item does (a card further left in a shelf is nearer and wins).
    private var edgeStrip: some View {
        Button {} label: {
            Color.clear.frame(width: 6).frame(maxHeight: .infinity)
        }
        .buttonStyle(EdgeStripStyle())
        .focused($edgeFocused)
        .disabled(!edgeEnabled)
    }

    private func enableEdge(after seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        if !menuOpen { edgeEnabled = true }
    }
}

private struct MenuRowLabel: View {
    let title: String
    let icon: String
    let selected: Bool
    let indent: Bool
    let trailing: String?
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: indent ? 22 : 26, weight: .semibold))
                .frame(width: 36)
            Text(title)
                .font(indent ? .callout : .headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let trailing {
                Image(systemName: trailing)
                    .font(.footnote.weight(.bold))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(isFocused ? Color.black : selected ? Theme.leaf : Color.white.opacity(0.85))
        .padding(.leading, indent ? 46 : 14)
        .padding(.trailing, 16)
        .padding(.vertical, indent ? 9 : 12)
        .frame(width: TVShell.menuWidth - 48, alignment: .leading)
        .background {
            Capsule().fill(isFocused ? Color.white : selected && !indent ? Color.white.opacity(0.1) : .clear)
        }
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

/// Draws nothing, focused or not.
private struct EdgeStripStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
    }
}

/// No system platter: the label draws its own focus capsule.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
#endif
