import Foundation
import SwiftUI

/// Video-frame thumbnails for files in the NAS browser, like Infuse's folder views. Rows ask when they appear
/// and withdraw when they scroll away; two files are grabbed at a time. Frames go to `ThumbnailStore` under the
/// file's library key, shared with the library and Continue Watching, so a file is grabbed only once.
@MainActor
final class BrowserThumbnails: ObservableObject {
    static let shared = BrowserThumbnails()

    /// Library keys whose frame is on disk.
    @Published private(set) var ready: Set<String> = []

    private struct Job {
        let key: String
        let location: String
        let server: ServerCredentials
    }

    private static let parallel = 2
    private var queue: [Job] = []
    private var running: Set<String> = []
    private var failed: Set<String> = []

    func request(server: ServerCredentials, item: RemoteItem) {
        let key = RemoteFileSystems.key(server: server, path: item.path)
        guard !ready.contains(key), !running.contains(key), !failed.contains(key),
              !queue.contains(where: { $0.key == key }) else { return }
        if let output = Self.output(for: key), FileManager.default.fileExists(atPath: output.path) {
            ready.insert(key)
            return
        }
        guard let url = RemoteFileSystems.playbackURL(server: server, path: item.path) else { return }
        queue.append(Job(key: key, location: url.absoluteString, server: server))
        pump()
    }

    /// The row scrolled away before its turn.
    func cancel(server: ServerCredentials, item: RemoteItem) {
        let key = RemoteFileSystems.key(server: server, path: item.path)
        queue.removeAll { $0.key == key }
    }

    static func reference(server: ServerCredentials, item: RemoteItem) -> String {
        ThumbnailStore.reference(forKey: RemoteFileSystems.key(server: server, path: item.path))
    }

    private static func output(for key: String) -> URL? {
        ThumbnailStore.url(for: ThumbnailStore.reference(forKey: key))
    }

    private func pump() {
        while running.count < Self.parallel, !queue.isEmpty {
            let job = queue.removeFirst()
            guard let output = Self.output(for: job.key) else { continue }
            running.insert(job.key)
            if job.server.kind == .smb { RemoteCredentialStore.shared.register(job.server) }
            Task {
                let location = job.location
                let probe = await Task.detached(priority: .utility) { FrameGrabber.grab(location, to: output, timeout: 30) }.value
                running.remove(job.key)
                if probe != nil { ready.insert(job.key) } else { failed.insert(job.key) }
                pump()
            }
        }
    }
}

/// Music rows in the NAS browser: same footprint as a video thumbnail.
struct BrowserAudioIcon: View {
    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: "music.note").font(.title3).foregroundStyle(Theme.leaf)
        }
        #if os(tvOS)
        .frame(width: 192, height: 108)
        #else
        .frame(width: 112, height: 63)
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The thumbnail at the start of a video row in the NAS browser.
struct BrowserThumbnail: View {
    @ObservedObject private var thumbnails = BrowserThumbnails.shared
    let server: ServerCredentials
    let item: RemoteItem

    #if os(tvOS)
    private static let size = CGSize(width: 192, height: 108)
    #else
    private static let size = CGSize(width: 112, height: 63)
    #endif

    var body: some View {
        let key = RemoteFileSystems.key(server: server, path: item.path)
        Group {
            if thumbnails.ready.contains(key) {
                ArtworkImage(path: BrowserThumbnails.reference(server: server, item: item), size: "w300", placeholderIcon: "play.rectangle.fill")
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "play.rectangle.fill").font(.title3).foregroundStyle(Theme.leaf)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear { thumbnails.request(server: server, item: item) }
        .onDisappear { thumbnails.cancel(server: server, item: item) }
    }
}
