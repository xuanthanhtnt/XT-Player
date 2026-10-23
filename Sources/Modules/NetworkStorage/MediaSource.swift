import Foundation

/// Something the player can open.
/// v0.1: local files picked by the user (security-scoped) and direct URLs
/// (http/https, or anything FFmpeg understands, e.g. a NAS WebDAV/HTTP share).
/// v0.2 adds SMB3 / WebDAV / NFS browsing on top of this type.
struct MediaSource: Hashable {
    let url: URL
    /// Security-scoped bookmark for user-picked files, so they reopen from "Recent" after relaunch.
    let bookmark: Data?

    init(url: URL, bookmark: Data? = nil) {
        self.url = url
        self.bookmark = bookmark
    }

    var displayName: String {
        if url.isFileURL { return url.lastPathComponent }
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? url.absoluteString) : last
    }

    /// Stable identity for the library. Credentials in a URL never become part of the key.
    var libraryKey: String {
        guard !url.isFileURL, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.standardizedFileURL.path
        }
        parts.user = nil
        parts.password = nil
        return parts.string ?? url.absoluteString
    }

    /// What mpv receives: a plain path for local files, the URL string otherwise.
    var playbackLocation: String {
        url.isFileURL ? url.path : url.absoluteString
    }

    // MARK: - Local files

    /// Wraps a URL returned by the system file picker; creates a bookmark while access is granted.
    static func pickedFile(_ url: URL) -> MediaSource {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let bookmark = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        return MediaSource(url: url, bookmark: bookmark)
    }

    /// Re-creates a source from a stored library entry (resolving the bookmark when there is one).
    static func restore(urlString: String, bookmark: Data?) -> MediaSource? {
        if let bookmark {
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                return MediaSource(url: url, bookmark: stale ? nil : bookmark)
            }
        }
        guard let url = URL(string: urlString) else { return nil }
        return MediaSource(url: url)
    }

    /// Parses user input ("nas.local:5005/movies/x.mkv", "https://…") into a source.
    static func fromUserInput(_ text: String) -> MediaSource? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: candidate) ?? URL(string: candidate.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(), supportedSchemes.contains(scheme), url.host != nil
        else { return nil }
        return MediaSource(url: url)
    }

    /// Protocols the bundled FFmpeg (MPVKit LGPL build) can stream directly.
    /// SMB/WebDAV browsing arrives with the NetworkStorage module in v0.2.
    static let supportedSchemes: Set<String> = ["http", "https", "rtsp", "rtmp", "ftp"]
}

/// Keeps a security-scoped resource open for as long as the player needs it.
final class SecurityScopedAccess {
    private let url: URL
    private let active: Bool

    init(_ url: URL) {
        self.url = url
        self.active = url.isFileURL && url.startAccessingSecurityScopedResource()
    }

    deinit {
        if active { url.stopAccessingSecurityScopedResource() }
    }
}
