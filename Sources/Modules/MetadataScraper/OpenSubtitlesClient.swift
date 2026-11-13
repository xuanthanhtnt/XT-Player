import Foundation

/// OpenSubtitles.com REST API v1: search (file hash + title), download, and an optional login that raises the
/// daily download quota. Needs a free API key (Settings ▸ OpenSubtitles, or the CI secret OPENSUBTITLES_API_KEY).
struct OpenSubtitlesClient {
    struct Subtitle: Identifiable, Hashable {
        let id: String
        let fileID: Int
        let language: String
        let release: String
        let downloads: Int
        let hearingImpaired: Bool
        let machineTranslated: Bool
        /// Found through the file hash: made for exactly this release.
        let hashMatch: Bool
    }

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "Chưa có API key OpenSubtitles — thêm trong Cài đặt ▸ Phụ đề trực tuyến."
            case let .http(401, _): return "OpenSubtitles từ chối API key hoặc tài khoản (401)."
            case let .http(406, message), let .http(429, message):
                return "Hết lượt tải hôm nay trên OpenSubtitles. \(message)"
            case let .http(code, message): return "OpenSubtitles lỗi \(code). \(message)"
            }
        }
    }

    let apiKey: String
    var username: String?
    var password: String?

    private static let host = "api.opensubtitles.com"

    static func current() -> OpenSubtitlesClient? {
        guard let key = AppSettings.openSubtitlesKey else { return nil }
        let user = AppSettings.defaults.string(forKey: AppSettings.openSubtitlesUser)
        return OpenSubtitlesClient(apiKey: key, username: user?.isEmpty == false ? user : nil,
                                   password: Keychain.get(account: "opensubtitles.password"))
    }

    // MARK: Search

    func search(query: String, year: Int?, season: Int?, episode: Int?, languages: [String], hash: String?) async throws -> [Subtitle] {
        var items: [String: String] = ["order_by": "download_count", "order_direction": "desc"]
        let codes = Self.languageCodes(languages)
        if !codes.isEmpty { items["languages"] = codes.joined(separator: ",") }
        if let hash { items["moviehash"] = hash }
        if !query.isEmpty { items["query"] = query.lowercased() }
        if let year, season == nil { items["year"] = "\(year)" }
        if let season { items["season_number"] = "\(season)" }
        if let episode { items["episode_number"] = "\(episode)" }

        // The API wants parameters sorted and lower-case (otherwise it answers with a redirect).
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = Self.host
        parts.path = "/api/v1/subtitles"
        parts.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { return [] }

        let data = try await send(URLRequest(url: url))
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return response.data.compactMap { item in
            guard let file = item.attributes.files.first else { return nil }
            return Subtitle(
                id: item.id,
                fileID: file.file_id,
                language: item.attributes.language ?? "",
                release: item.attributes.release ?? file.file_name ?? "",
                downloads: item.attributes.download_count ?? 0,
                hearingImpaired: item.attributes.hearing_impaired ?? false,
                machineTranslated: (item.attributes.machine_translated ?? false) || (item.attributes.ai_translated ?? false),
                hashMatch: item.attributes.moviehash_match ?? false
            )
        }
    }

    // MARK: Download

    /// Downloads the subtitle file into Caches/Subtitles and returns its location.
    func download(_ subtitle: Subtitle) async throws -> URL {
        var host = Self.host
        var token: String?
        if let username, let password, !password.isEmpty {
            let login = try await self.login(username: username, password: password)
            token = login.token
            if let base = login.base_url, !base.isEmpty { host = base }
        }
        guard let url = URL(string: "https://\(host)/api/v1/download") else { throw Failure.http(0, "") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(["file_id": subtitle.fileID])
        let link = try JSONDecoder().decode(DownloadResponse.self, from: try await send(request))
        guard let fileURL = URL(string: link.link) else { throw Failure.http(0, link.message ?? "") }

        let (data, response) = try await URLSession.shared.data(from: fileURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.http(http.statusCode, "")
        }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (link.file_name ?? "\(subtitle.fileID).srt").replacingOccurrences(of: "/", with: "_")
        let target = folder.appendingPathComponent("\(subtitle.fileID)-\(name)")
        try data.write(to: target, options: .atomic)
        return target
    }

    // MARK: Plumbing

    private func login(username: String, password: String) async throws -> LoginResponse {
        guard let url = URL(string: "https://\(Self.host)/api/v1/login") else { throw Failure.http(0, "") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        return try JSONDecoder().decode(LoginResponse.self, from: try await send(request))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("XT-Player v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.text ?? ""
            throw Failure.http(status, message)
        }
        return data
    }

    /// "vi,vie,en,eng" → ["en", "vi"]: two-letter codes, sorted as the API expects.
    static func languageCodes(_ preferred: [String]) -> [String] {
        Array(Set(preferred.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0.count == 2 })).sorted()
    }

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable {
                struct File: Decodable {
                    let file_id: Int
                    let file_name: String?
                }

                let language: String?
                let download_count: Int?
                let release: String?
                let hearing_impaired: Bool?
                let machine_translated: Bool?
                let ai_translated: Bool?
                let moviehash_match: Bool?
                let files: [File]
            }

            let id: String
            let attributes: Attributes
        }

        let data: [Item]
    }

    private struct DownloadResponse: Decodable {
        let link: String
        let file_name: String?
        let message: String?
    }

    private struct LoginResponse: Decodable {
        let token: String
        let base_url: String?
    }

    private struct ErrorResponse: Decodable {
        let message: String?
        let errors: [String]?

        var text: String { message ?? errors?.joined(separator: " ") ?? "" }
    }
}

/// The OpenSubtitles file hash: size + the 64-bit little-endian words of the first and last 64 KiB.
enum OpenSubtitlesHash {
    private static let chunk = 64 * 1024

    /// Blocking; call off the main thread. SMB (xtsmb://) and local files; nil for anything else.
    static func compute(location: String) -> String? {
        if location.hasPrefix("xtsmb:") {
            guard let stream = SMBReadStream.open(uri: location) else { return nil }
            defer {
                stream.cancel()
                stream.close()
            }
            return hash(size: stream.size) { offset in read(stream, at: offset) }
        }
        guard !location.contains("://"), let handle = FileHandle(forReadingAtPath: location),
              let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }
        return hash(size: Int64(size)) { offset in
            try? handle.seek(toOffset: UInt64(offset))
            return try? handle.read(upToCount: chunk)
        }
    }

    private static func hash(size: Int64, read: (Int64) -> Data?) -> String? {
        guard size >= Int64(chunk) * 2, let head = read(0), let tail = read(size - Int64(chunk)),
              head.count == chunk, tail.count == chunk else { return nil }
        var value = UInt64(size)
        for data in [head, tail] {
            data.withUnsafeBytes { raw in
                for index in stride(from: 0, to: chunk, by: 8) {
                    value &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", value)
    }

    private static func read(_ stream: SMBReadStream, at offset: Int64) -> Data? {
        guard stream.seek(to: offset) == offset else { return nil }
        var data = Data(count: chunk)
        var filled = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return false }
            while filled < chunk {
                let n = stream.read(into: base.advanced(by: filled), count: chunk - filled)
                if n <= 0 { return n == 0 }
                filled += Int(n)
            }
            return true
        }
        return ok ? data.prefix(filled) : nil
    }
}
