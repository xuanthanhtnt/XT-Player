import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Navigation destinations inside a section.
enum Route: Hashable {
    case grid(kind: String)
    case detail(itemKey: String)
    case browser(serverID: String, path: String, title: String)
    case addServer
    case settings
}

/// Top-level sections (sidebar on Mac / iPad / Apple TV, tab bar on iPhone).
/// The Mac sidebar is grouped like Infuse's: Library filters, then Files (servers and library folders).
enum AppSection: Hashable {
    case home, movies, shows, sources, settings
    case search, recent, unwatched, topRated, genres
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
    #endif

    var body: some View {
        content
            .modifier(UpdatePromptModifier())
            .environment(\.play, PlayAction { session = $0 })
            .environment(\.openSection, { section = $0 })
            .environmentObject(scanner)
            .task {
                await TraktService.shared.sync(context: context)
                await scanner.generateMissingArtwork(context: context)
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
    /// library folders, opened straight in the browser), then Settings.
    private var sections: some View {
        TabView(selection: $section) {
            Tab("Tìm kiếm", systemImage: "magnifyingglass", value: AppSection.search) {
                NavigationStack { LibrarySearchView().libraryRoutes() }
            }
            Tab("Trang chủ", systemImage: "house", value: AppSection.home) {
                NavigationStack { HomeView().libraryRoutes() }
            }
            TabSection("Thư viện") {
                Tab("Phim", systemImage: "film", value: AppSection.movies) {
                    NavigationStack { LibraryGridView(filter: .movies).libraryRoutes() }
                }
                Tab("TV Shows", systemImage: "tv", value: AppSection.shows) {
                    NavigationStack { LibraryGridView(filter: .shows).libraryRoutes() }
                }
                Tab("Mới thêm", systemImage: "clock.arrow.circlepath", value: AppSection.recent) {
                    NavigationStack { LibraryGridView(filter: .recent).libraryRoutes() }
                }
                Tab("Chưa xem", systemImage: "eye.slash", value: AppSection.unwatched) {
                    NavigationStack { LibraryGridView(filter: .unwatched).libraryRoutes() }
                }
                Tab("Điểm cao", systemImage: "star", value: AppSection.topRated) {
                    NavigationStack { LibraryGridView(filter: .topRated).libraryRoutes() }
                }
                Tab("Thể loại", systemImage: "theatermasks", value: AppSection.genres) {
                    NavigationStack { GenresView().libraryRoutes() }
                }
            }
            TabSection("Tệp") {
                ForEach(servers) { server in
                    Tab(server.name, systemImage: server.kind.icon, value: AppSection.server(server.id)) {
                        NavigationStack { BrowserView(serverID: server.id, path: "", title: server.name).libraryRoutes() }
                    }
                }
                ForEach(folders) { folder in
                    Tab(folder.name, systemImage: "folder", value: AppSection.folder(folder.key)) {
                        NavigationStack { BrowserView(serverID: folder.serverID, path: folder.path, title: folder.name).libraryRoutes() }
                    }
                }
                Tab("Nguồn", systemImage: "externaldrive.badge.plus", value: AppSection.sources) {
                    NavigationStack { SourcesView().libraryRoutes() }
                }
            }
            Tab("Cài đặt", systemImage: "gearshape", value: AppSection.settings) {
                NavigationStack { SettingsView().libraryRoutes() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: servers.map(\.id)) { _, ids in
            // A removed server or folder must not leave the sidebar pointing at nothing.
            if case let .server(id) = section, !ids.contains(id) { section = .sources }
        }
        .onChange(of: folders.map(\.key)) { _, keys in
            if case let .folder(key) = section, !keys.contains(key) { section = .sources }
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
        for ext in ["mkv", "mka", "webm", "m2ts", "mts", "ts", "wmv", "flv", "vob", "iso", "rmvb", "ogm", "mpg", "mpeg"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()
}

private struct LibraryRoutes: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case let .grid(kind):
                LibraryGridView(kind: LibraryKind(rawValue: kind) ?? .movie)
            case let .detail(itemKey):
                MediaDetailView(itemKey: itemKey)
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
