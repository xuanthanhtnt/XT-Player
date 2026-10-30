import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Navigation destinations inside a section.
enum Route: Hashable {
    case grid(kind: String)
    case detail(itemKey: String)
    case album(itemKey: String)
    case browser(serverID: String, path: String, title: String)
    case addServer
    case settings
}

/// Top-level sections (sidebar on Mac / iPad / Apple TV, tab bar on iPhone).
/// The Mac sidebar is grouped like Infuse's: Library filters, then Files (servers and library folders).
enum AppSection: Hashable {
    case home, movies, shows, sources, settings
    case search, recent, unwatched, topRated, genres
    case musicVideos, music
    case server(String), folder(String)
}

/// Starts playback from anywhere in the view tree.
struct PlayAction {
    let handler: (PlaybackSession) -> Void
    func callAsFunction(_ session: PlaybackSession) { handler(session) }
}

private struct PlayActionKey: EnvironmentKey {
    static let defaultValue = PlayAction { _ in }
}

private struct SectionActionKey: EnvironmentKey {
    static let defaultValue: (AppSection) -> Void = { _ in }
}

extension EnvironmentValues {
    var play: PlayAction {
        get { self[PlayActionKey.self] }
        set { self[PlayActionKey.self] = newValue }
    }

    /// Switches the top-level section (e.g. the Home hero's "Add source" button).
    var openSection: (AppSection) -> Void {
        get { self[SectionActionKey.self] }
        set { self[SectionActionKey.self] = newValue }
    }
}

extension Notification.Name {
    static let xtOpenFileRequested = Notification.Name("xt.openFileRequested")
    static let xtOpenURLRequested = Notification.Name("xt.openURLRequested")
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: PlaybackSession?
    @State private var section: AppSection = .home
    @State private var showImporter = false
    @State private var showURLSheet = false
    @State private var errorMessage: String?
    @StateObject private var scanner = LibraryScanner()
    #if os(macOS)
    @Query(sort: \MediaServer.createdAt) private var servers: [MediaServer]
    @Query(sort: \LibraryFolder.name) private var folders: [LibraryFolder]
    /// Size of the library when playback started: it keeps it while the window takes the video's shape.
    @State private var librarySize: CGSize = .zero
    @State private var frozenLibrarySize: CGSize?
    /// Navigation inside each sidebar section, kept while another section is shown.
    @State private var paths: [AppSection: [Route]] = [:]
    #endif

    var body: some View {
        content
            .modifier(UpdatePromptModifier())
            .environment(\.play, PlayAction { session = $0 })
            .environment(\.openSection, { section = $0 })
            .environmentObject(scanner)
            // A file just played may have no picture yet (opened from a share or from this device).
            .onChange(of: session == nil) { _, closed in
                guard closed else { return }
                Task {
                    await scanner.generateMissingArtwork(context: context)
                    // Give Trakt a moment to file the stop scrobble, then pull what changed meanwhile.
                    try? await Task.sleep(for: .seconds(3))
                    await TraktService.shared.sync(context: context)
                }
            }
            // Watched elsewhere (Infuse, Apple TV, phone) while this app sat in the background.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await TraktService.shared.syncIfStale(context: context) } }
            }
            .onChange(of: scanner.isScanning) { _, scanning in
                // New library files may be ones Trakt already has as watched.
                if !scanning { Task { await TraktService.shared.sync(context: context) } }
            }
            .task {
                await scanner.identifyUnmatched(context: context)
                await TraktService.shared.sync(context: context)
                await scanner.generateMissingArtwork(context: context)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(900))
                    if session == nil { await TraktService.shared.syncIfStale(context: context, interval: 600) }
                }
            }
            #if !os(tvOS)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.playableTypes, allowsMultipleSelection: false) { result in
                switch result {
                case let .success(urls):
                    if let url = urls.first {
                        session = PlaybackSession(item: PlaybackFactory.local(MediaSource.pickedFile(url), context: context))
                    }
                case let .failure(error):
                    errorMessage = error.localizedDescription
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .xtOpenFileRequested)) { _ in showImporter = true }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .xtOpenURLRequested)) { _ in showURLSheet = true }
            .sheet(isPresented: $showURLSheet) {
                OpenURLSheet { source in
                    showURLSheet = false
                    session = PlaybackSession(item: PlaybackFactory.local(source, context: context))
                }
            }
            .alert("Không mở được", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        ZStack {
            // The library stays alive underneath so its navigation survives playback. Meanwhile it keeps its
            // size and sets no minimum window size, so the window can take the video's shape (or shrink to
            // the mini player) without the sidebar collapsing behind it.
            let frozen = frozenLibrarySize
            sections
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    if session == nil { librarySize = size }
                }
                .frame(width: frozen?.width, height: frozen?.height)
                .frame(minWidth: frozen == nil ? nil : 0, maxWidth: frozen == nil ? nil : .infinity,
                       minHeight: frozen == nil ? nil : 0, maxHeight: frozen == nil ? nil : .infinity)
                .opacity(session == nil ? 1 : 0)
                .allowsHitTesting(session == nil)
            if let session {
                PlayerScreen(session: session) { self.session = nil }
                    .transition(.opacity)
            }
        }
        .onChange(of: session?.id) { _, id in
            if id == nil {
                frozenLibrarySize = nil
            } else if frozenLibrarySize == nil, librarySize.width > 0 {
                frozenLibrarySize = librarySize
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session?.id)
        // While playing, PlayerWindowController hides the window toolbar through AppKit: SwiftUI's
        // .toolbar(.hidden, for: .windowToolbar) would take the close / minimise / zoom buttons with it.
        #else
        sections
            .fullScreenCover(item: $session) { current in
                PlayerScreen(session: current) { session = nil }
            }
        #endif
    }

    #if os(macOS)
    /// Infuse's sidebar: Search, Home, then "Thư viện" (library filters) and "Tệp" (servers and the
    /// library folders, opened straight in the browser), with Settings pinned to the bottom.
    ///
    /// A split view rather than a sidebar TabView: a TabView cannot pin a tab to the bottom of its sidebar
    /// (a tab hidden from the list shows an empty page). Each section remembers where it was navigated to.
    private var sections: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                sidebarRow("Tìm kiếm", "magnifyingglass", .search)
                sidebarRow("Trang chủ", "house", .home)
                Section("Thư viện") {
                    sidebarRow("Phim", "film", .movies)
                    sidebarRow("TV Shows", "tv", .shows)
                    sidebarRow("Mới thêm", "clock.arrow.circlepath", .recent)
                    sidebarRow("Chưa xem", "eye.slash", .unwatched)
                    sidebarRow("Điểm cao", "star", .topRated)
                    sidebarRow("Thể loại", "theatermasks", .genres)
                }
                Section("Âm nhạc") {
                    sidebarRow("Nhạc", "music.note.list", .music)
                    sidebarRow("Video ca nhạc", "music.note.tv", .musicVideos)
                }
                Section("Tệp") {
                    ForEach(servers) { server in
                        sidebarRow(server.name, server.kind.icon, .server(server.id))
                    }
                    ForEach(folders) { folder in
                        sidebarRow(folder.name, "folder", .folder(folder.key))
                    }
                    sidebarRow("Nguồn", "externaldrive.badge.plus", .sources)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarSettingsButton(selected: section == .settings) { section = .settings }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            let current = section
            NavigationStack(path: Binding(get: { paths[current] ?? [] }, set: { paths[current] = $0 })) {
                page(for: current).libraryRoutes()
            }
            .id(current)
        }
        .onChange(of: servers.map(\.id)) { _, ids in
            // A removed server or folder must not leave the sidebar pointing at nothing.
            if case let .server(id) = section, !ids.contains(id) { section = .sources }
        }
        .onChange(of: folders.map(\.key)) { _, keys in
            if case let .folder(key) = section, !keys.contains(key) { section = .sources }
        }
    }

    /// The list selects every section except Settings, which has its own row below the list.
    private var sidebarSelection: Binding<AppSection?> {
        Binding(get: { section == .settings ? nil : section }, set: { if let value = $0 { section = value } })
    }

    private func sidebarRow(_ title: String, _ icon: String, _ value: AppSection) -> some View {
        Label(title, systemImage: icon).tag(value)
    }

    @ViewBuilder
    private func page(for section: AppSection) -> some View {
        switch section {
        case .search: LibrarySearchView()
        case .home: HomeView()
        case .movies: LibraryGridView(filter: .movies)
        case .shows: LibraryGridView(filter: .shows)
        case .recent: LibraryGridView(filter: .recent)
        case .unwatched: LibraryGridView(filter: .unwatched)
        case .topRated: LibraryGridView(filter: .topRated)
        case .genres: GenresView()
        case .music: AlbumsView()
        case .musicVideos: MusicVideosView()
        case .sources: SourcesView()
        case .settings: SettingsView()
        case let .server(id):
            if let server = servers.first(where: { $0.id == id }) {
                BrowserView(serverID: server.id, path: "", title: server.name)
            }
        case let .folder(key):
            if let folder = folders.first(where: { $0.key == key }) {
                BrowserView(serverID: folder.serverID, path: folder.path, title: folder.name)
            }
        }
    }
    #else
    private var sections: some View {
        TabView(selection: $section) {
            Tab("Trang chủ", systemImage: "house.fill", value: AppSection.home) {
                NavigationStack { HomeView().libraryRoutes() }
            }
            Tab("Phim", systemImage: "film.fill", value: AppSection.movies) {
                NavigationStack { LibraryGridView(kind: .movie).libraryRoutes() }
            }
            Tab("TV Shows", systemImage: "tv.fill", value: AppSection.shows) {
                NavigationStack { LibraryGridView(kind: .show).libraryRoutes() }
            }
            Tab("Nhạc", systemImage: "music.note", value: AppSection.music) {
                NavigationStack { MusicLibraryView().libraryRoutes() }
            }
            Tab("Nguồn", systemImage: "externaldrive.connected.to.line.below.fill", value: AppSection.sources) {
                NavigationStack { SourcesView().libraryRoutes() }
            }
            Tab("Cài đặt", systemImage: "gearshape.fill", value: AppSection.settings) {
                NavigationStack { SettingsView().libraryRoutes() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
    #endif

    static let playableTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .mpeg2TransportStream, .avi, .audio]
        let extensions = FilenameParser.videoExtensions.union(FilenameParser.audioExtensions).sorted()
        for ext in extensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()
}

#if os(macOS)
/// Settings row at the bottom of the Mac sidebar, drawn like a sidebar row (⌘, opens it too).
private struct SidebarSettingsButton: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(selected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tint))
                        .frame(width: 20)
                    Text("Cài đặt")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(selected ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}
#endif

private struct LibraryRoutes: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case let .grid(kind):
                switch LibraryKind(rawValue: kind) ?? .movie {
                case .album: AlbumsView()
                case .musicVideo: MusicVideosView()
                case let other: LibraryGridView(kind: other)
                }
            case let .detail(itemKey):
                MediaDetailView(itemKey: itemKey)
            case let .album(itemKey):
                AlbumDetailView(itemKey: itemKey)
            case let .browser(serverID, path, title):
                BrowserView(serverID: serverID, path: path, title: title)
            case .addServer:
                AddServerView()
            case .settings:
                SettingsView()
            }
        }
    }
}

extension View {
    func libraryRoutes() -> some View { modifier(LibraryRoutes()) }
}
