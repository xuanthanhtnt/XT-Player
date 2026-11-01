import Foundation

/// TMDb API v3 client. Accepts either a v3 API key or a v4 read-access token (JWT, sent as Bearer).
struct TMDbClient {
    let credential: String
    let language: String

    private static let base = URL(string: "https://api.themoviedb.org/3/")!
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func current() -> TMDbClient? {
        guard let credential = AppSettings.tmdbCredential else { return nil }
        let language = AppSettings.defaults.string(forKey: AppSettings.metadataLanguage) ?? "vi-VN"
        return TMDbClient(credential: credential, language: language)
    }

    static func imageURL(_ path: String?, size: String = "w500") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let local = ThumbnailStore.url(for: path) { return local }
        if path.hasPrefix("http") {
            // Trakt artwork (no TMDb key): its CDN has thumb / medium / full renditions of each image.
            guard TraktMetadata.isTraktImage(path) else { return URL(string: path) }
            let rendition: String
            switch size {
            case "w92", "w154", "w185", "w300": rendition = "thumb"
            case "w342", "w500", "w780": rendition = "medium"
            default: rendition = "full"
            }
            return URL(string: path.replacingOccurrences(of: "/medium/", with: "/\(rendition)/"))
        }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    // MARK: Endpoints

    func searchMovie(_ title: String, year: Int?) async throws -> TMDbSearchResult? {
        if let year, let hit = try await search("search/movie", ["query": title, "year": "\(year)"]).first { return hit }
        return try await search("search/movie", ["query": title]).first
    }

    func searchShow(_ title: String, year: Int?) async throws -> TMDbSearchResult? {
        if let year, let hit = try await search("search/tv", ["query": title, "first_air_date_year": "\(year)"]).first { return hit }
        return try await search("search/tv", ["query": title]).first
    }

    func movie(_ id: Int) async throws -> TMDbDetails {
        var details: TMDbDetails = try await get("movie/\(id)", ["append_to_response": "credits"])
        if (details.overview ?? "").isEmpty, language != "en-US" {
            let english: TMDbDetails = try await get("movie/\(id)", [:], language: "en-US")
            details.overview = english.overview
        }
        return details
    }

    func show(_ id: Int) async throws -> TMDbDetails {
        var details: TMDbDetails = try await get("tv/\(id)", ["append_to_response": "credits"])
        if (details.overview ?? "").isEmpty, language != "en-US" {
            let english: TMDbDetails = try await get("tv/\(id)", [:], language: "en-US")
            details.overview = english.overview
        }
        return details
    }

    func season(show id: Int, number: Int) async throws -> TMDbSeason {
        try await get("tv/\(id)/season/\(number)", [:])
    }

    // MARK: Plumbing

    private func search(_ path: String, _ query: [String: String]) async throws -> [TMDbSearchResult] {
        var params = query
        params["include_adult"] = "false"
        let page: TMDbPage = try await get(path, params)
        return page.results
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String], language: String? = nil) async throws -> T {
        guard var parts = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw RemoteError.invalidAddress
        }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: language ?? self.language))
        let isToken = credential.hasPrefix("eyJ")
        if !isToken { items.append(URLQueryItem(name: "api_key", value: credential)) }
        parts.queryItems = items
        guard let url = parts.url else { throw RemoteError.invalidAddress }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isToken { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw RemoteError.badResponse(status) }
        return try Self.decoder.decode(T.self, from: data)
    }
}

struct TMDbPage: Decodable {
    let results: [TMDbSearchResult]
}

struct TMDbSearchResult: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let posterPath: String?
    let backdropPath: String?
}

struct TMDbDetails: Decodable {
    struct Genre: Decodable { let name: String }
    struct Credits: Decodable {
        struct Person: Decodable {
            let name: String
            let character: String?
            let profilePath: String?
        }
        let cast: [Person]
    }

    let id: Int
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    var overview: String?
    let tagline: String?
    let releaseDate: String?
    let firstAirDate: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let genres: [Genre]?
    let credits: Credits?

    var displayTitle: String? { title ?? name }
    var year: Int? { (releaseDate ?? firstAirDate).flatMap { Int($0.prefix(4)) } }
}

struct TMDbSeason: Decodable {
    struct Episode: Decodable {
        let episodeNumber: Int
        let name: String?
        let overview: String?
        let stillPath: String?
        let airDate: String?
    }
    let seasonNumber: Int
    let episodes: [Episode]
}
