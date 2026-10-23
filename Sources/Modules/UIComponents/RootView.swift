import SwiftUI

/// One playback request handed from the library to the player.
struct PlaybackSession: Identifiable {
    let id = UUID()
    let source: MediaSource
    let title: String
    let startAt: Double?
    let entry: MediaEntry?
}

struct RootView: View {
    @State private var session: PlaybackSession?

    var body: some View {
        #if os(macOS)
        ZStack {
            if let session {
                PlayerScreen(session: session) { self.session = nil }
                    .transition(.opacity)
            } else {
                HomeView { session = $0 }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session?.id)
        #else
        HomeView { session = $0 }
            .fullScreenCover(item: $session) { current in
                PlayerScreen(session: current) { session = nil }
            }
        #endif
    }
}
