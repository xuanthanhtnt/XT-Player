import Foundation
import SwiftData

enum ServerKind: String, CaseIterable, Identifiable {
    case smb
    case webdav

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smb: return "SMB (Windows / NAS)"
        case .webdav: return "WebDAV"
        }
    }

    var icon: String {
        switch self {
        case .smb: return "externaldrive.connected.to.line.below"
        case .webdav: return "globe"
        }
    }
}

/// A NAS / file server the user added. The password lives in the Keychain under `id`.
@Model
final class MediaServer {
    @Attribute(.unique) var id: String
    var name: String
    var kindRaw: String
    var host: String
    /// 0 = protocol default (445 for SMB, 80/443 for WebDAV).
    var port: Int
    var username: String
    var domain: String
    var useTLS: Bool
    /// WebDAV root, e.g. "/" or "/dav/media".
    var basePath: String
    var allowInsecureTLS: Bool
    var createdAt: Date

    init(name: String, kind: ServerKind, host: String, port: Int = 0, username: String = "", domain: String = "",
         useTLS: Bool = false, basePath: String = "/", allowInsecureTLS: Bool = true) {
        self.id = UUID().uuidString.lowercased()
        self.name = name
        self.kindRaw = kind.rawValue
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.useTLS = useTLS
        self.basePath = basePath
        self.allowInsecureTLS = allowInsecureTLS
        self.createdAt = .now
    }

    var kind: ServerKind { ServerKind(rawValue: kindRaw) ?? .smb }

    var displayHost: String { port > 0 ? "\(host):\(port)" : host }

    /// Reads the password from the Keychain — call once per operation, not per row render.
    var credentials: ServerCredentials {
        ServerCredentials(
            id: id, kind: kind, host: host, port: port, username: username,
            password: Keychain.get(account: "server.\(id)") ?? "", domain: domain,
            useTLS: useTLS, basePath: basePath, allowInsecureTLS: allowInsecureTLS
        )
    }

    func setPassword(_ password: String) {
        Keychain.set(password, account: "server.\(id)")
    }
}

/// Everything needed to talk to a server, safe to hand to background threads (mpv's demuxer, scanners).
struct ServerCredentials: Hashable, Sendable {
    let id: String
    let kind: ServerKind
    let host: String
    let port: Int
    let username: String
    let password: String
    let domain: String
    let useTLS: Bool
    let basePath: String
    let allowInsecureTLS: Bool

    var displayHost: String { port > 0 ? "\(host):\(port)" : host }
}

/// A folder of a server that feeds the library (scanned recursively).
@Model
final class LibraryFolder {
    @Attribute(.unique) var key: String
    var serverID: String
    var path: String
    var name: String
    var lastScan: Date?
    var fileCount: Int

    init(serverID: String, path: String, name: String) {
        self.key = "\(serverID):\(path)"
        self.serverID = serverID
        self.path = path
        self.name = name
        self.fileCount = 0
    }
}

enum LibraryKind: String {
    case movie
    case show
    /// Concerts, music videos, live shows: kept out of Films and never looked up on TMDb / Trakt.
    case musicVideo
    /// A folder of audio tracks. Its files are the tracks: `episode` = track number, `season` = disc,
    /// `episodeTitle` = track title; the album artist is kept in `tagline` (see `artist`).
    case album
}

/// What a library folder holds, which decides how its files are recognised. Kept in UserDefaults by folder key,
/// so the SwiftData store needs no migration (a failed one would replace the store).
enum LibraryFolderKind: String, CaseIterable, Identifiable {
    case films, musicVideos, music

    var id: String { rawValue }

    var label: String {
        switch self {
        case .films: return "Phim & TV"
        case .musicVideos: return "Video ca nhạc"
        case .music: return "Nhạc"
        }
    }

    var icon: String {
        switch self {
        case .films: return "film"
        case .musicVideos: return "music.note.tv"
        case .music: return "music.note.list"
        }
    }

    private static let storeKey = "library.folderKinds"

    static func of(_ folderKey: String) -> LibraryFolderKind {
        let stored = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]
        return stored?[folderKey].flatMap(LibraryFolderKind.init(rawValue:)) ?? .films
    }

    static func set(_ kind: LibraryFolderKind?, for folderKey: String) {
        var stored = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        stored[folderKey] = kind?.rawValue
        UserDefaults.standard.set(stored, forKey: storeKey)
    }

    /// First guess when a folder is added. Its name first: "Music Videos", "MV", "Concert", "Live", "Karaoke",
    /// "Ca nhạc" → music videos; "Music", "Nhạc", "Audio", "Albums", "Lossless", "FLAC", "DSD" → music. Otherwise
    /// what it holds: mostly audio → music, else films.
    static func guess(name: String, items: [RemoteItem]) -> LibraryFolderKind {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if folded.contains("music video") || folded.contains("ca nhac") || folded.contains("video nhac")
            || !words.isDisjoint(with: ["mv", "mvs", "concert", "concerts", "live", "karaoke", "liveshow"]) {
            return .musicVideos
        }
        if !words.isDisjoint(with: ["music", "nhac", "audio", "album", "albums", "songs", "lossless", "flac", "dsd", "sacd", "hires"]) {
            return .music
        }
        let audio = items.filter(\.isAudio).count, video = items.filter(\.isVideo).count
        return audio > 0 && audio >= video ? .music : .films
    }
}

/// A movie or a TV show, enriched from TMDb when an API key is configured.
@Model
final class LibraryItem {
    @Attribute(.unique) var key: String
    var kindRaw: String
    var title: String
    var originalTitle: String?
    var year: Int?
    var overview: String?
    var tagline: String?
    var posterPath: String?
    var backdropPath: String?
    var rating: Double?
    var runtime: Int?
    var genres: [String]
    var tmdbID: Int?
    /// "Name|Character|/profile.jpg"
    var cast: [String]
    var addedAt: Date
    var updatedAt: Date

    init(key: String, kind: LibraryKind, title: String, year: Int?) {
        self.key = key
        self.kindRaw = kind.rawValue
        self.title = title
        self.year = year
        self.genres = []
        self.cast = []
        self.addedAt = .now
        self.updatedAt = .now
    }

    var kind: LibraryKind { LibraryKind(rawValue: kindRaw) ?? .movie }

    /// Album artist (albums keep it in `tagline`); music videos keep their folder (artist / show) there too.
    var artist: String? { kind == .album || kind == .musicVideo ? tagline : nil }

    var castMembers: [CastMember] {
        cast.compactMap { raw in
            let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            return CastMember(name: name, character: parts.count > 1 ? parts[1] : "", profilePath: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
        }
    }
}

struct CastMember: Hashable, Identifiable {
    var id: String { name + character }
    let name: String
    let character: String
    let profilePath: String?
}

/// One playable file of the library (a movie version or an episode).
@Model
final class LibraryFile {
    /// Same as `MediaSource.libraryKey` of its playback URL, so progress is shared with `MediaEntry`.
    @Attribute(.unique) var key: String
    var itemKey: String
    var folderKey: String
    var serverID: String?
    /// SMB: "Share/dir/file.mkv"; WebDAV: "/dav/dir/file.mkv"; local: absolute path.
    var path: String
    var fileName: String
    var size: Int64
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var episodeOverview: String?
    var stillPath: String?
    var airDate: String?
    var subtitlePaths: [String]
    var badges: [String]
    var addedAt: Date

    init(key: String, itemKey: String, folderKey: String, serverID: String?, path: String, fileName: String, size: Int64) {
        self.key = key
        self.itemKey = itemKey
        self.folderKey = folderKey
        self.serverID = serverID
        self.path = path
        self.fileName = fileName
        self.size = size
        self.subtitlePaths = []
        self.badges = []
        self.addedAt = .now
    }

    var episodeCode: String? {
        guard let season, let episode else { return nil }
        return "S\(season < 10 ? "0" : "")\(season)E\(episode < 10 ? "0" : "")\(episode)"
    }
}
