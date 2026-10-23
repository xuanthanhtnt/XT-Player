import SwiftData
import SwiftUI

@main
struct XTPlayerApp: App {
    init() {
        AppSettings.registerDefaults()
        // Posters and backdrops are re-used constantly while browsing the library.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(for: [MediaEntry.self, MediaServer.self, LibraryFolder.self, LibraryItem.self, LibraryFile.self])
        #if os(macOS)
        .defaultSize(width: 1280, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Mở tệp video…") {
                    NotificationCenter.default.post(name: .xtOpenFileRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Mở URL…") {
                    NotificationCenter.default.post(name: .xtOpenURLRequested, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let xtOpenFileRequested = Notification.Name("xt.openFileRequested")
    static let xtOpenURLRequested = Notification.Name("xt.openURLRequested")
}
