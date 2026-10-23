import Foundation
import SwiftData

/// One playable item the user has opened, with its resume point ("Continue Watching").
/// `key` is the credential-free playback URL, shared with `LibraryFile.key`.
@Model
final class MediaEntry {
    @Attribute(.unique) var key: String
    var title: String
    /// Credential-free location (local path, xtsmb://server/share/path, https://host/path).
    var urlString: String
    var bookmark: Data?
    var isLocalFile: Bool
    var lastPlayedAt: Date
    var position: Double
    var duration: Double
    var tags: [String]
    /// Network source the file lives on (credentials are fetched from the Keychain at play time).
    var serverID: String?
    /// Secondary line, e.g. the show name for an episode.
    var subtitle: String?
    /// TMDb image path (still or backdrop) for the Continue Watching card.
    var artworkPath: String?

    init(key: String, title: String, urlString: String, bookmark: Data?, isLocalFile: Bool, tags: [String]) {
        self.key = key
        self.title = title
        self.urlString = urlString
        self.bookmark = bookmark
        self.isLocalFile = isLocalFile
        self.lastPlayedAt = .now
        self.position = 0
        self.duration = 0
        self.tags = tags
    }

    /// 0...1, or nil when nothing worth resuming has been watched yet.
    var progress: Double? {
        guard duration > 0, position > 0 else { return nil }
        return min(1, position / duration)
    }

    /// Where playback should start: resume unless the item was (nearly) finished.
    var resumePosition: Double? {
        guard position > 30, duration <= 0 || position < duration - 60 else { return nil }
        return position
    }

    var isWatched: Bool { duration > 0 && position >= duration - 60 }
}

enum MediaLibrary {
    static func entry(forKey key: String, in context: ModelContext) -> MediaEntry? {
        var descriptor = FetchDescriptor<MediaEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Find or create the entry for a playback item and mark it as just played.
    static func touch(_ item: PlaybackItem, in context: ModelContext) -> MediaEntry {
        let source = item.source
        let key = source.libraryKey
        if let existing = entry(forKey: key, in: context) {
            existing.lastPlayedAt = .now
            existing.title = item.title
            existing.subtitle = item.subtitle
            if let art = item.artworkPath { existing.artworkPath = art }
            if let bookmark = source.bookmark { existing.bookmark = bookmark }
            return existing
        }
        let parsed = FilenameParser.parse(source.displayName)
        let entry = MediaEntry(
            key: key,
            title: item.title,
            urlString: key,
            bookmark: source.bookmark,
            isLocalFile: source.url.isFileURL,
            tags: parsed.badges
        )
        entry.serverID = item.server?.id
        entry.subtitle = item.subtitle
        entry.artworkPath = item.artworkPath
        context.insert(entry)
        return entry
    }

    static func setWatched(_ watched: Bool, key: String, title: String, in context: ModelContext) {
        let entry = entry(forKey: key, in: context) ?? {
            let e = MediaEntry(key: key, title: title, urlString: key, bookmark: nil, isLocalFile: key.hasPrefix("/"), tags: [])
            context.insert(e)
            return e
        }()
        if watched {
            if entry.duration <= 0 { entry.duration = 1 }
            entry.position = entry.duration
        } else {
            entry.position = 0
        }
        try? context.save()
    }

    static func saveProgress(_ entry: MediaEntry, position: Double, duration: Double, in context: ModelContext) {
        guard position.isFinite, duration.isFinite else { return }
        entry.position = max(0, position)
        if duration > 0 { entry.duration = duration }
        entry.lastPlayedAt = .now
        try? context.save()
    }
}
