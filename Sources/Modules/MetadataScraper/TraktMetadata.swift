import Foundation

/// Library metadata from Trakt when no TMDb key is set: search with details and artwork
/// (`extended=full,images`), Vietnamese titles and overviews (translations), cast with headshots, and episode
/// titles and stills. Only the app's Client ID is needed — no login — so a release build recognises films out
/// of the box, and every match carries the TMDb id that Trakt sync and a later TMDb key both use.
struct TraktMetadata {
    let clientID: String
    /// ISO 639-1 code for translations ("vi"); nil keeps Trakt's English.
    let language: String?

    static func current() -> TraktMetadata? {
        guard let client = AppSettings.traktClient else { return nil }
        let setting = AppSettings.defaults.string(forKey: AppSettings.metadataLanguage) ?? "vi-VN"
        let code = String(setting.prefix(2))
        return TraktMetadata(clientID: client.id, language: code == "en" ? nil : code)
    }

    /// Artwork from Trakt's image CDN, recognisable in `posterPath` / `backdropPath`.
    static func isTraktImage(_ path: String?) -> Bool { path?.hasPrefix("https://media.trakt.tv/") == true }

    struct Details {
        var traktID: Int
        var tmdbID: Int?
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
        var cast: [String]
    }

    struct Episode {
        let number: Int
        let title: String?
        let overview: String?
        let stillPath: String?
        let airDate: String?
    }

    func movie(title: String, year: Int?) async throws -> Details? {
        try await find("movie", title: title, year: year)
    }

    func show(title: String, year: Int?) async throws -> Details? {
        try await find("show", title: title, year: year)
    }

    /// Trakt id of a show the library already knows by its TMDb id (episode info on a later scan).
    func showID(tmdb: Int) async throws -> Int? {
        let results = try await getArray("/search/tmdb/\(tmdb)", ["type": "show"])
        return ((results.first?["show"] as? [String: Any])?["ids"] as? [String: Any])?["trakt"] as? Int
    }

    func season(show traktID: Int, number: Int) async throws -> [Episode] {
        var query = ["extended": "full,images"]
        if let language { query["translations"] = language }
        return try await getArray("/shows/\(traktID)/seasons/\(number)", query).compactMap { episode in
            guard let number = episode["number"] as? Int else { return nil }
            let translation = (episode["translations"] as? [[String: Any]])?.first
            return Episode(
                number: number,
                title: Self.text(translation?["title"]) ?? Self.text(episode["title"]),
                overview: Self.text(translation?["overview"]) ?? Self.text(episode["overview"]),
                stillPath: Self.image(episode["images"], "screenshot"),
                airDate: (episode["first_aired"] as? String).map { String($0.prefix(10)) }
            )
        }
    }

    // MARK: - Matching

    private func find(_ type: String, title: String, year: Int?) async throws -> Details? {
        var query = ["query": title, "fields": "title,aliases,translations", "extended": "full,images", "limit": "10"]
        if let year { query["years"] = "\(year)" }
        let objects = try await getArray("/search/\(type)", query).compactMap { $0[type] as? [String: Any] }
        guard let object = Self.pick(objects, title: title, yearGiven: year != nil),
              let traktID = (object["ids"] as? [String: Any])?["trakt"] as? Int else { return nil }
        return try await details(type, object: object, traktID: traktID)
    }

    /// An exact title (or original title) wins. Without one, the first hit is taken only when the file named
    /// a year (the search is limited to it) and the titles share most of their words, or it is the only hit:
    /// home videos and concerts must not turn into some unrelated film.
    private static func pick(_ objects: [[String: Any]], title: String, yearGiven: Bool) -> [String: Any]? {
        let wanted = TraktMedia.normalize(title)
        guard !wanted.isEmpty else { return nil }
        if let exact = objects.first(where: { object in
            [object["title"], object["original_title"]].contains { TraktMedia.normalize($0 as? String ?? "") == wanted }
        }) {
            return exact
        }
        guard yearGiven, let first = objects.first else { return nil }
        return objects.count == 1 || wordOverlap(title, first["title"] as? String ?? "") >= 0.5 ? first : nil
    }

    private static func wordOverlap(_ a: String, _ b: String) -> Double {
        func words(_ text: String) -> Set<String> {
            Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(min(left.count, right.count))
    }

    private func details(_ type: String, object: [String: Any], traktID: Int) async throws -> Details {
        let path = type == "movie" ? "/movies/\(traktID)" : "/shows/\(traktID)"
        var details = Details(
            traktID: traktID,
            tmdbID: (object["ids"] as? [String: Any])?["tmdb"] as? Int,
            title: object["title"] as? String ?? "",
            originalTitle: Self.text(object["original_title"]),
            year: object["year"] as? Int,
            overview: Self.text(object["overview"]),
            tagline: Self.text(object["tagline"]),
            posterPath: Self.image(object["images"], "poster"),
            backdropPath: Self.image(object["images"], "fanart"),
            rating: (object["rating"] as? Double).flatMap { $0 > 0 ? $0 : nil },
            runtime: (object["runtime"] as? Int).flatMap { $0 > 0 ? $0 : nil },
            genres: ((object["genres"] as? [String]) ?? []).map { Self.genreName($0, language: language) },
            cast: []
        )
        if let language, let translation = try? await getArray("\(path)/translations/\(language)", [:]).first {
            if let title = Self.text(translation["title"]) {
                if details.originalTitle == nil { details.originalTitle = details.title }
                details.title = title
            }
            details.overview = Self.text(translation["overview"]) ?? details.overview
            details.tagline = Self.text(translation["tagline"]) ?? details.tagline
        }
        if let people = try? await getObject("\(path)/people", ["extended": "images"]),
           let cast = people["cast"] as? [[String: Any]] {
            details.cast = cast.prefix(15).compactMap { member in
                guard let person = member["person"] as? [String: Any], let name = person["name"] as? String else { return nil }
                let character = member["character"] as? String ?? (member["characters"] as? [String])?.first ?? ""
                return "\(name)|\(character)|\(Self.image(person["images"], "headshot") ?? "")"
            }
        }
        return details
    }

    // MARK: - Values

    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Trakt image URLs come without a scheme ("media.trakt.tv/images/…/medium/….webp").
    private static func image(_ images: Any?, _ kind: String) -> String? {
        guard let path = ((images as? [String: Any])?[kind] as? [String])?.first, !path.isEmpty else { return nil }
        return path.hasPrefix("http") ? path : "https://\(path)"
    }

    private static func genreName(_ slug: String, language: String?) -> String {
        if language == "vi", let name = vietnameseGenres[slug] { return name }
        return slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static let vietnameseGenres: [String: String] = [
        "action": "Hành động", "adventure": "Phiêu lưu", "animation": "Hoạt hình", "anime": "Anime",
        "biography": "Tiểu sử", "children": "Thiếu nhi", "comedy": "Hài", "crime": "Hình sự",
        "documentary": "Tài liệu", "drama": "Chính kịch", "family": "Gia đình", "fantasy": "Giả tưởng",
        "history": "Lịch sử", "holiday": "Lễ hội", "horror": "Kinh dị", "music": "Âm nhạc", "musical": "Nhạc kịch",
        "mystery": "Bí ẩn", "news": "Tin tức", "reality": "Truyền hình thực tế", "romance": "Lãng mạn",
        "science-fiction": "Khoa học viễn tưởng", "short": "Phim ngắn", "soap": "Truyền hình dài tập",
        "sport": "Thể thao", "sporting-event": "Sự kiện thể thao", "superhero": "Siêu anh hùng",
        "suspense": "Hồi hộp", "talk-show": "Talk show", "thriller": "Gây cấn", "war": "Chiến tranh",
        "western": "Miền Tây", "mini-series": "Phim ngắn tập",
    ]

    // MARK: - HTTP

    private func getArray(_ path: String, _ query: [String: String]) async throws -> [[String: Any]] {
        (try JSONSerialization.jsonObject(with: try await get(path, query)) as? [[String: Any]]) ?? []
    }

    private func getObject(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: try await get(path, query)) as? [String: Any]) ?? [:]
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> Data {
        var parts = URLComponents(string: "https://api.trakt.tv" + path)!
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("XT-Player/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")",
                         forHTTPHeaderField: "User-Agent")
        for attempt in 0..<4 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429, attempt < 3 {
                let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(for: .seconds(min(30, max(1, wait))))
                continue
            }
            guard (200...299).contains(status) else { throw URLError(.badServerResponse) }
            return data
        }
        throw URLError(.badServerResponse)
    }
}
