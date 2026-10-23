import Foundation
import SMBClient

/// One entry of a remote directory listing.
struct RemoteItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    /// SMB: "Share/dir/name"; WebDAV: absolute server path "/dav/dir/name".
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isVideo: Bool { !isDirectory && FilenameParser.videoExtensions.contains(fileExtension) }
    var isSubtitle: Bool { !isDirectory && FilenameParser.subtitleExtensions.contains(fileExtension) }
    var baseName: String { (name as NSString).deletingPathExtension }
}

protocol RemoteFileSystem: AnyObject {
    /// Lists `path` ("" = root: SMB shares, or the WebDAV base path).
    func list(_ path: String) async throws -> [RemoteItem]
    func close() async
}

enum RemoteError: LocalizedError {
    case badResponse(Int)
    case invalidAddress
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .badResponse(code): return "Máy chủ trả về lỗi HTTP \(code)."
        case .invalidAddress: return "Địa chỉ máy chủ không hợp lệ."
        case let .message(text): return text
        }
    }
}

enum RemoteFileSystems {
    static func make(_ server: ServerCredentials) -> RemoteFileSystem {
        switch server.kind {
        case .smb: return SMBFileSystem(server)
        case .webdav: return WebDAVFileSystem(server)
        }
    }

    /// Playback URL handed to mpv. SMB goes through the app's `xtsmb://` stream bridge
    /// (credentials are looked up by server id, never put in the URL); WebDAV is plain HTTP(S).
    static func playbackURL(server: ServerCredentials, path: String) -> URL? {
        var parts = URLComponents()
        switch server.kind {
        case .smb:
            parts.scheme = "xtsmb"
            parts.host = server.id
            parts.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case .webdav:
            parts.scheme = server.useTLS ? "https" : "http"
            parts.host = server.host
            if server.port > 0 { parts.port = server.port }
            if !server.username.isEmpty {
                parts.user = server.username
                parts.password = server.password
            }
            parts.path = path.hasPrefix("/") ? path : "/" + path
        }
        return parts.url
    }

    /// Credential-free identity of a remote file (shared by the library and the resume points).
    static func key(server: ServerCredentials, path: String) -> String {
        guard let url = playbackURL(server: server, path: path) else { return "\(server.id):\(path)" }
        return MediaSource(url: url).libraryKey
    }
}

// MARK: - SMB2/3

/// Browsing through kishikawakatsumi/SMBClient (pure Swift over Network.framework — works on tvOS,
/// where libsmb2-based clients fail to tree-connect).
actor SMBFileSystem: RemoteFileSystem {
    private let server: ServerCredentials
    private var client: SMBClient?
    private var connectedShare: String?

    init(_ server: ServerCredentials) {
        self.server = server
    }

    func list(_ path: String) async throws -> [RemoteItem] {
        let client = try await connectedClient()
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let share = parts.first else {
            let shares = try await client.listShares()
            return shares
                .filter { ($0.type.rawValue & 0x0FFF_FFFF) == 0 && !$0.name.hasSuffix("$") }
                .map { RemoteItem(name: $0.name, path: $0.name, isDirectory: true, size: 0, modified: nil) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if connectedShare != share {
            if connectedShare != nil { _ = try? await client.disconnectShare() }
            _ = try await client.connectShare(share)
            connectedShare = share
        }
        let subPath = parts.dropFirst().joined(separator: "/")
        let files = try await client.listDirectory(path: subPath)
        return files
            .filter { $0.name != "." && $0.name != ".." && !$0.isHidden && !$0.name.hasPrefix(".") }
            .map { file in
                RemoteItem(name: file.name, path: parts.joined(separator: "/") + "/" + file.name,
                           isDirectory: file.isDirectory, size: Int64(file.size), modified: file.lastWriteTime)
            }
    }

    func close() async {
        if let client {
            _ = try? await client.logoff()
            client.session.disconnect()
        }
        client = nil
        connectedShare = nil
    }

    private func connectedClient() async throws -> SMBClient {
        if let client { return client }
        let client = try await SMBLogin.connect(server)
        self.client = client
        return client
    }
}

enum SMBLogin {
    /// Connects and authenticates (NTLMv2; empty user name = guest, then anonymous).
    static func connect(_ server: ServerCredentials) async throws -> SMBClient {
        let client = server.port > 0 ? SMBClient(host: server.host, port: server.port) : SMBClient(host: server.host)
        let domain = server.domain.isEmpty ? nil : server.domain
        do {
            if server.username.isEmpty {
                do {
                    try await client.login(username: "guest", password: nil, domain: domain)
                } catch {
                    try await client.login(username: nil, password: nil)
                }
            } else {
                try await client.login(username: server.username, password: server.password, domain: domain)
            }
            return client
        } catch {
            client.session.disconnect()
            throw error
        }
    }
}

// MARK: - WebDAV

/// PROPFIND-based browsing (Depth: 1). Handles Basic/Digest auth and, when allowed, self-signed TLS.
final class WebDAVFileSystem: NSObject, RemoteFileSystem, URLSessionTaskDelegate {
    private let server: ServerCredentials
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(_ server: ServerCredentials) {
        self.server = server
    }

    func list(_ path: String) async throws -> [RemoteItem] {
        var directory = path.isEmpty ? server.basePath : path
        if directory.isEmpty { directory = "/" }
        if !directory.hasPrefix("/") { directory = "/" + directory }
        if !directory.hasSuffix("/") { directory += "/" }

        var parts = URLComponents()
        parts.scheme = server.useTLS ? "https" : "http"
        parts.host = server.host
        if server.port > 0 { parts.port = server.port }
        parts.path = directory
        guard let url = parts.url else { throw RemoteError.invalidAddress }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !server.username.isEmpty, let token = "\(server.username):\(server.password)".data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 207 || status == 200 else { throw RemoteError.badResponse(status) }

        let normalizedSelf = Self.normalize(directory)
        return WebDAVParser.parse(data)
            .filter { Self.normalize($0.path) != normalizedSelf }
            .filter { !$0.name.hasPrefix(".") && !$0.name.hasPrefix("@") && $0.name != "#recycle" }
    }

    func close() async {
        session.invalidateAndCancel()
    }

    private static func normalize(_ path: String) -> String {
        var p = path.removingPercentEncoding ?? path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if server.allowInsecureTLS, let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            if challenge.previousFailureCount == 0, !server.username.isEmpty {
                completionHandler(.useCredential, URLCredential(user: server.username, password: server.password, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Parses a WebDAV multistatus body into items.
final class WebDAVParser: NSObject, XMLParserDelegate {
    private struct Entry {
        var href = ""
        var displayName = ""
        var length: Int64 = 0
        var isCollection = false
        var modified: Date?
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""

    static func parse(_ data: Data) -> [RemoteItem] {
        let delegate = WebDAVParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries.compactMap { entry in
            var path = entry.href
            if path.lowercased().hasPrefix("http"), let url = URL(string: path) { path = url.path }
            path = path.removingPercentEncoding ?? path
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let name = entry.displayName.isEmpty ? (trimmed as NSString).lastPathComponent : entry.displayName
            guard !name.isEmpty else { return nil }
            return RemoteItem(name: name, path: trimmed.isEmpty ? "/" : trimmed, isDirectory: entry.isCollection,
                              size: entry.length, modified: entry.modified)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response": current = Entry()
        case "collection": current?.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href": current?.href = value
        case "displayname": current?.displayName = value
        case "getcontentlength": current?.length = Int64(value) ?? 0
        case "getlastmodified": current?.modified = Self.dateFormatter.date(from: value)
        case "response":
            if let current { entries.append(current) }
            current = nil
        default: break
        }
        text = ""
    }
}
