import Foundation
import SwiftData

/// One playable item the user has opened, with its resume point.
/// v0.1 stores local files (security-scoped bookmark) and direct URLs; v0.3 adds TMDb metadata.
@Model
final class MediaEntry {
    @Attribute(.unique) var key: String
    var title: String
    var urlString: String
    var bookmark: Data?
    var isLocalFile: Bool
    var lastPlayedAt: Date
    var position: Double
    var duration: Double
    var tags: [String]

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
    /// Find or create the entry for a source and mark it as just played.
    static func touch(_ source: MediaSource, in context: ModelContext) -> MediaEntry {
        let key = source.libraryKey
        let parsed = FilenameParser.parse(source.displayName)
        var descriptor = FetchDescriptor<MediaEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.lastPlayedAt = .now
            if let bookmark = source.bookmark { existing.bookmark = bookmark }
            return existing
        }
        let entry = MediaEntry(
            key: key,
            title: parsed.displayTitle,
            urlString: source.url.absoluteString,
            bookmark: source.bookmark,
            isLocalFile: source.url.isFileURL,
            tags: parsed.badges
        )
        context.insert(entry)
        return entry
    }

    static func saveProgress(_ entry: MediaEntry, position: Double, duration: Double, in context: ModelContext) {
        guard position.isFinite, duration.isFinite else { return }
        entry.position = max(0, position)
        if duration > 0 { entry.duration = duration }
        entry.lastPlayedAt = .now
        try? context.save()
    }
}
