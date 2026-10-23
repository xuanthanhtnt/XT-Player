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
enum AppSection: Hashable {
    case home, movies, shows, sources, settings
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

    var body: some View {
        content
            .environment(\.play, PlayAction { session = $0 })
            .environment(\.openSection, { section = $0 })
            .environmentObject(scanner)
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
            // The library stays alive underneath so its navigation survives playback.
            sections
                .opacity(session == nil ? 1 : 0)
                .allowsHitTesting(session == nil)
            if let session {
                PlayerScreen(session: session) { self.session = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session?.id)
        // Video gets the whole window: no toolbar while playing (the title bar is already transparent).
        .toolbar(session == nil ? .automatic : .hidden, for: .windowToolbar)
        #else
        sections
            .fullScreenCover(item: $session) { current in
                PlayerScreen(session: current) { session = nil }
            }
        #endif
    }

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
