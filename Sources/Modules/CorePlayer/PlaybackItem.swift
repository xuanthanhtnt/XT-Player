import Foundation
import SwiftData

/// One entry of the play queue.
struct PlaybackItem: Identifiable, Hashable {
    let id = UUID()
    let source: MediaSource
    let title: String
    var subtitle: String?
    /// TMDb image path for Now Playing / Continue Watching.
    var artworkPath: String?
    var server: ServerCredentials?
    /// Sidecar subtitle locations (playback URLs) loaded with the file.
    var externalSubtitles: [String] = []
    var startAt: Double?

    var key: String { source.libraryKey }
}

/// What the player is asked to play: a queue and where to start.
struct PlaybackSession: Identifiable {
    let id = UUID()
    let items: [PlaybackItem]
    let startIndex: Int

    init(items: [PlaybackItem], startIndex: Int = 0) {
        self.items = items
        self.startIndex = max(0, min(startIndex, items.count - 1))
    }

    init(item: PlaybackItem) {
        self.init(items: [item], startIndex: 0)
    }
}

/// Builds playback items from the different places media comes from.
enum PlaybackFactory {
    static func local(_ source: MediaSource, context: ModelContext) -> PlaybackItem {
        let parsed = FilenameParser.parse(source.displayName)
        var item = PlaybackItem(source: source, title: parsed.displayTitle)
        item.startAt = MediaLibrary.entry(forKey: source.libraryKey, in: context)?.resumePosition
        return item
    }

    /// A file picked in the network browser; siblings become the queue (folder order), sidecar subtitles attach.
    static func remote(files: [RemoteItem], subtitles: [RemoteItem], server: ServerCredentials, context: ModelContext) -> [PlaybackItem] {
        files.compactMap { file in
            guard let url = RemoteFileSystems.playbackURL(server: server, path: file.path) else { return nil }
            let parsed = FilenameParser.parse(file.name)
            var item = PlaybackItem(source: MediaSource(url: url), title: parsed.displayTitle)
            item.server = server
            let base = file.baseName.lowercased()
            var subs = subtitles.filter { $0.baseName.lowercased().hasPrefix(base) }
            if subs.isEmpty, files.count == 1 { subs = subtitles }
            item.externalSubtitles = subs.compactMap { RemoteFileSystems.playbackURL(server: server, path: $0.path)?.absoluteString }
            item.startAt = MediaLibrary.entry(forKey: item.key, in: context)?.resumePosition
            return item
        }
    }

    /// Library files of one item (a movie's versions, or a show's episodes in order).
    static func library(_ files: [LibraryFile], item: LibraryItem, context: ModelContext) -> [PlaybackItem] {
        files.compactMap { file in
            guard let serverID = file.serverID, let server = server(id: serverID, context: context),
                  let url = RemoteFileSystems.playbackURL(server: server, path: file.path) else { return nil }
            let title: String
            let subtitle: String?
            if item.kind == .show, let code = file.episodeCode {
                title = file.episodeTitle.map { "\(code) · \($0)" } ?? code
                subtitle = item.title
            } else {
                title = item.year.map { "\(item.title) (\($0))" } ?? item.title
                subtitle = file.badges.isEmpty ? nil : file.badges.joined(separator: " · ")
            }
            var playback = PlaybackItem(source: MediaSource(url: url), title: title, subtitle: subtitle)
            playback.server = server
            playback.artworkPath = file.stillPath ?? item.backdropPath ?? item.posterPath
            playback.externalSubtitles = file.subtitlePaths.compactMap { RemoteFileSystems.playbackURL(server: server, path: $0)?.absoluteString }
            playback.startAt = MediaLibrary.entry(forKey: playback.key, in: context)?.resumePosition
            return playback
        }
    }

    /// Re-opens a Continue Watching entry.
    static func resume(_ entry: MediaEntry, context: ModelContext) -> PlaybackItem? {
        if let serverID = entry.serverID {
            guard let server = server(id: serverID, context: context),
                  let stored = URL(string: entry.urlString),
                  let url = credentialed(stored, server: server) else { return nil }
            var item = PlaybackItem(source: MediaSource(url: url), title: entry.title, subtitle: entry.subtitle)
            item.server = server
            item.artworkPath = entry.artworkPath
            item.startAt = entry.resumePosition
            if let file = libraryFile(key: entry.key, context: context) {
                item.externalSubtitles = file.subtitlePaths.compactMap { RemoteFileSystems.playbackURL(server: server, path: $0)?.absoluteString }
            }
            return item
        }
        guard let source = MediaSource.restore(urlString: entry.urlString, bookmark: entry.bookmark) else { return nil }
        var item = PlaybackItem(source: source, title: entry.title, subtitle: entry.subtitle)
        item.startAt = entry.resumePosition
        return item
    }

    static func server(id: String, context: ModelContext) -> ServerCredentials? {
        var d = FetchDescriptor<MediaServer>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d).first)?.credentials
    }

    static func libraryFile(key: String, context: ModelContext) -> LibraryFile? {
        var d = FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    /// Adds the stored password back into a WebDAV URL (SMB URLs carry no credentials).
    private static func credentialed(_ url: URL, server: ServerCredentials) -> URL? {
        guard server.kind == .webdav, !server.username.isEmpty,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.user = server.username
        parts.password = server.password
        return parts.url
    }
}
