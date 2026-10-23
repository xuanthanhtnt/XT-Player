import SwiftUI

/// Navigation destinations of the library.
enum Route: Hashable {
    case grid(kind: String)
    case detail(itemKey: String)
    case browser(serverID: String, path: String, title: String)
    case addServer
    case settings
}

/// Starts playback from anywhere in the view tree.
struct PlayAction {
    let handler: (PlaybackSession) -> Void
    func callAsFunction(_ session: PlaybackSession) { handler(session) }
}

private struct PlayActionKey: EnvironmentKey {
    static let defaultValue = PlayAction { _ in }
}

extension EnvironmentValues {
    var play: PlayAction {
        get { self[PlayActionKey.self] }
        set { self[PlayActionKey.self] = newValue }
    }
}

struct RootView: View {
    @State private var session: PlaybackSession?
    @StateObject private var scanner = LibraryScanner()

    var body: some View {
        #if os(macOS)
        ZStack {
            // The library stays alive underneath so its navigation survives playback.
            HomeView()
                .opacity(session == nil ? 1 : 0)
                .allowsHitTesting(session == nil)
            if let session {
                PlayerScreen(session: session) { self.session = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session?.id)
        .environment(\.play, PlayAction { session = $0 })
        .environmentObject(scanner)
        #else
        HomeView()
            .environment(\.play, PlayAction { session = $0 })
            .environmentObject(scanner)
            .fullScreenCover(item: $session) { current in
                PlayerScreen(session: current) { session = nil }
            }
        #endif
    }
}
