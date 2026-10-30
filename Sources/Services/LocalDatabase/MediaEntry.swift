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
        guard position > 30, !isWatched else { return nil }
        return position
    }

    /// Finished: the last minute reached, or 90 % (end credits of a film, the outro of a music video).
    var isWatched: Bool { duration > 0 && (position >= duration - 60 || position >= duration * 0.9) }

    /// Opened and played for a while, finished or not ("Unwatched" leaves these out, like Infuse).
    var isStarted: Bool { position > 10 || isWatched }
}

enum MediaLibrary {
    private static let resolutionBadges: Set<String> = ["4K", "1080p", "720p", "SD"]

    /// What playback or the artwork probe found out about a library file: its resolution badge (when the file
    /// name has none) and, for movies TMDb did not match, the running time — like Infuse's "2 hrs 40 min · 1080p".
    static func learn(fileKey: String, resolution: String, duration: Double, in context: ModelContext) {
        var fileQuery = FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.key == fileKey })
        fileQuery.fetchLimit = 1
        guard let file = try? context.fetch(fileQuery).first else { return }
        var changed = false
        if !resolution.isEmpty, !file.badges.contains(where: resolutionBadges.contains) {
            file.badges.insert(resolution, at: 0)
            changed = true
        }
        let itemKey = file.itemKey
        var itemQuery = FetchDescriptor<LibraryItem>(predicate: #Predicate { $0.key == itemKey })
        itemQuery.fetchLimit = 1
        if duration > 60, let item = try? context.fetch(itemQuery).first, item.kind == .movie, item.runtime == nil {
            item.runtime = Int((duration / 60).rounded())
            changed = true
        }
        if changed { try? context.save() }
    }

    /// What a track turned out to be when played ("FLAC · 96 kHz · 24-bit"), kept as the file's second badge.
    static func learnTrack(fileKey: String, quality: String, in context: ModelContext) {
        var fileQuery = FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.key == fileKey })
        fileQuery.fetchLimit = 1
        guard let file = try? context.fetch(fileQuery).first else { return }
        let format = file.badges.first ?? quality
        guard file.badges.count < 2 || file.badges[1] != quality else { return }
        file.badges = [format, quality]
        try? context.save()
    }

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

    /// A new entry for a library file that has not been played on this device yet.
    static func makeEntry(key: String, title: String, in context: ModelContext) -> MediaEntry {
        let entry = MediaEntry(key: key, title: title, urlString: key, bookmark: nil, isLocalFile: key.hasPrefix("/"), tags: [])
        context.insert(entry)
        return entry
    }

    /// Marks watched / unwatched here and on Trakt when connected.
    @MainActor
    static func setWatched(_ watched: Bool, key: String, title: String, in context: ModelContext) {
        let entry = entry(forKey: key, in: context) ?? makeEntry(key: key, title: title, in: context)
        if watched {
            if entry.duration <= 0 { entry.duration = 1 }
            entry.position = entry.duration
        } else {
            entry.position = 0
        }
        try? context.save()
        if let media = TraktMedia.from(fileKey: key, fallbackName: nil, in: context) {
            TraktService.shared.setWatched(watched, media: [media])
        }
    }

    static func saveProgress(_ entry: MediaEntry, position: Double, duration: Double, in context: ModelContext) {
        guard position.isFinite, duration.isFinite else { return }
        entry.position = max(0, position)
        if duration > 0 { entry.duration = duration }
        entry.lastPlayedAt = .now
        try? context.save()
    }
}
