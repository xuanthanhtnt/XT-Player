import Foundation
import SwiftData

/// A movie or an episode as Trakt identifies it (TMDb id when the library has one, else title / year).
enum TraktMedia: Hashable {
    case movie(title: String, year: Int?, tmdb: Int?)
    case episode(show: String, year: Int?, tmdb: Int?, season: Int, number: Int)

    /// Scrobble body part: {"movie": …} or {"show": …, "episode": …}.
    var scrobbleObject: [String: Any] {
        switch self {
        case let .movie(title, year, tmdb):
            return ["movie": Self.object(title: title, year: year, tmdb: tmdb)]
        case let .episode(show, year, tmdb, season, number):
            return ["show": Self.object(title: show, year: year, tmdb: tmdb), "episode": ["season": season, "number": number]]
        }
    }

    /// Same title/year/id for matching Trakt lists against the library.
    var identity: String {
        switch self {
        case let .movie(title, year, tmdb):
            return tmdb.map { "m:tmdb:\($0)" } ?? "m:\(Self.normalize(title))|\(year ?? 0)"
        case let .episode(show, _, tmdb, season, number):
            return (tmdb.map { "e:tmdb:\($0)" } ?? "e:\(Self.normalize(show))") + ":\(season):\(number)"
        }
    }

    static func object(title: String, year: Int?, tmdb: Int?) -> [String: Any] {
        var object: [String: Any] = ["title": title]
        if let year { object["year"] = year }
        if let tmdb { object["ids"] = ["tmdb": tmdb] }
        return object
    }

    static func normalize(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// What a playable library file is on Trakt; files outside the library are recognised from their name.
    @MainActor
    static func from(fileKey: String, fallbackName: String?, in context: ModelContext) -> TraktMedia? {
        var fileQuery = FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.key == fileKey })
        fileQuery.fetchLimit = 1
        if let file = try? context.fetch(fileQuery).first {
            let itemKey = file.itemKey
            var itemQuery = FetchDescriptor<LibraryItem>(predicate: #Predicate { $0.key == itemKey })
            itemQuery.fetchLimit = 1
            if let item = try? context.fetch(itemQuery).first {
                if item.kind == .show, let season = file.season, let episode = file.episode {
                    return .episode(show: item.title, year: item.year, tmdb: item.tmdbID, season: season, number: episode)
                }
                // Unmatched home videos / concerts would only create noise on Trakt.
                guard item.tmdbID != nil || item.year != nil else { return nil }
                return .movie(title: item.title, year: item.year, tmdb: item.tmdbID)
            }
        }
        guard let fallbackName else { return nil }
        let parsed = FilenameParser.parse(fallbackName)
        switch parsed.kind {
        case let .episode(season, episode):
            return .episode(show: parsed.title, year: nil, tmdb: nil, season: season, number: episode)
        case .movie:
            guard parsed.year != nil else { return nil }
            return .movie(title: parsed.title, year: parsed.year, tmdb: nil)
        }
    }
}

/// Trakt.tv: device-code login (also on Apple TV), scrobbling, watched history both ways, and resume points
/// shared with other devices and apps (Infuse included) through /sync/playback.
@MainActor
final class TraktService: ObservableObject {
    static let shared = TraktService()

    enum Phase: Equatable {
        case disconnected
        case awaitingCode(code: String, url: String)
        case connected
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var username = ""
    @Published private(set) var status = ""
    @Published private(set) var isSyncing = false

    private struct Token: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private static let api = "https://api.trakt.tv"
    private static let tokenAccount = "trakt.token"
    private static let usernameKey = "trakt.username"
    static let scrobbleKey = "trakt.scrobble"

    private var token: Token?
    private var loginTask: Task<Void, Never>?

    private init() {
        if let data = Keychain.get(account: Self.tokenAccount)?.data(using: .utf8),
           let saved = try? JSONDecoder().decode(Token.self, from: data) {
            token = saved
            phase = .connected
            username = UserDefaults.standard.string(forKey: Self.usernameKey) ?? ""
        }
    }

    var isConnected: Bool { phase == .connected }
    var hasAppCredentials: Bool { AppSettings.traktClient != nil }
    private var scrobbleEnabled: Bool { UserDefaults.standard.object(forKey: Self.scrobbleKey) as? Bool ?? true }

    // MARK: Login

    func startLogin(context: ModelContext) {
        guard let client = AppSettings.traktClient else {
            status = "Nhập Client ID của ứng dụng Trakt trước."
            return
        }
        loginTask?.cancel()
        loginTask = Task {
            do {
                let code = try await post("/oauth/device/code", ["client_id": client.id], authorized: false)
                guard let deviceCode = code["device_code"] as? String, let userCode = code["user_code"] as? String else {
                    throw TraktError.message("Trakt không trả mã kích hoạt.")
                }
                phase = .awaitingCode(code: userCode, url: code["verification_url"] as? String ?? "https://trakt.tv/activate")
                status = ""
                var interval = Double(code["interval"] as? Int ?? 5)
                let deadline = Date().addingTimeInterval(Double(code["expires_in"] as? Int ?? 600))
                while Date() < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    let (status, body) = try await raw("/oauth/device/token", method: "POST",
                                                       body: Self.withSecret(["code": deviceCode, "client_id": client.id], client.secret),
                                                       authorized: false)
                    switch status {
                    case 200:
                        try store(body)
                        phase = .connected
                        await loadUsername()
                        await sync(context: context)
                        return
                    case 400: continue                      // the user has not entered the code yet
                    case 429: interval += 1                 // polling too fast
                    case 418: throw TraktError.message("Bạn đã từ chối kết nối trên Trakt.")
                    case 410: throw TraktError.message("Mã đã hết hạn — bấm Kết nối lại.")
                    default: throw TraktError.http(status)
                    }
                }
                if !Task.isCancelled { throw TraktError.message("Mã đã hết hạn — bấm Kết nối lại.") }
            } catch is CancellationError {
                return
            } catch {
                phase = token == nil ? .disconnected : .connected
                status = error.localizedDescription
            }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        phase = token == nil ? .disconnected : .connected
    }

    func disconnect() {
        if let token, let client = AppSettings.traktClient {
            let access = token.access
            Task { _ = try? await raw("/oauth/revoke", method: "POST", body: Self.withSecret(["token": access, "client_id": client.id], client.secret), authorized: false) }
        }
        token = nil
        Keychain.set(nil, account: Self.tokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        username = ""
        phase = .disconnected
        status = ""
    }

    // MARK: Scrobble

    enum ScrobbleAction: String {
        case start, pause, stop
    }

    /// `progress` 0…100. A stop under 80 % keeps a resume point on Trakt; at 80 % or more the item is watched.
    func scrobble(_ action: ScrobbleAction, media: TraktMedia, progress: Double) {
        guard isConnected, scrobbleEnabled, progress.isFinite else { return }
        var body = media.scrobbleObject
        body["progress"] = min(100, max(0, (progress * 100).rounded() / 100))
        Task { _ = try? await raw("/scrobble/\(action.rawValue)", method: "POST", body: body, authorized: true) }
    }

    // MARK: History

    func setWatched(_ watched: Bool, media: [TraktMedia]) {
        guard isConnected, !media.isEmpty else { return }
        let body = Self.historyBody(media)
        Task { _ = try? await raw(watched ? "/sync/history" : "/sync/history/remove", method: "POST", body: body, authorized: true) }
    }

    private static func historyBody(_ media: [TraktMedia]) -> [String: Any] {
        var movies: [[String: Any]] = []
        var shows: [String: (object: [String: Any], seasons: [Int: [Int]])] = [:]
        for item in media {
            switch item {
            case let .movie(title, year, tmdb):
                movies.append(TraktMedia.object(title: title, year: year, tmdb: tmdb))
            case let .episode(show, year, tmdb, season, number):
                let key = tmdb.map { "\($0)" } ?? TraktMedia.normalize(show)
                var entry = shows[key] ?? (TraktMedia.object(title: show, year: year, tmdb: tmdb), [:])
                entry.seasons[season, default: []].append(number)
                shows[key] = entry
            }
        }
        let showList: [[String: Any]] = shows.values.map { entry in
            var object = entry.object
            object["seasons"] = entry.seasons.sorted { $0.key < $1.key }.map { ["number": $0.key, "episodes": $0.value.map { ["number": $0] }] }
            return object
        }
        return ["movies": movies, "shows": showList]
    }

    // MARK: Sync

    /// Pulls resume points and watched history into the library and pushes local "watched" Trakt lacks.
    func sync(context: ModelContext) async {
        guard isConnected, !isSyncing else { return }
        isSyncing = true
        status = "Đang đồng bộ Trakt…"
        defer { isSyncing = false }
        do {
            let index = TraktLibraryIndex.build(context: context)
            let playback = try await getList("/sync/playback")
            let watchedMovies = try await getList("/sync/watched/movies")
            let watchedShows = try await getList("/sync/watched/shows")

            var resumed = 0
            for item in playback {
                guard let media = Self.media(from: item), let progress = item["progress"] as? Double,
                      let pausedAt = Self.date(item["paused_at"]) else { continue }
                for key in index.keys(for: media) {
                    if applyResume(key: key, progress: progress, at: pausedAt, index: index, context: context) { resumed += 1 }
                }
            }

            var remoteWatched = Set<String>()
            var marked = 0
            for item in watchedMovies {
                guard let movie = item["movie"] as? [String: Any], let media = Self.movie(movie) else { continue }
                remoteWatched.insert(media.identity)
                let at = Self.date(item["last_watched_at"]) ?? .distantPast
                for key in index.keys(for: media) {
                    if markWatched(key: key, at: at, index: index, context: context) { marked += 1 }
                }
            }
            for item in watchedShows {
                guard let show = item["show"] as? [String: Any], let seasons = item["seasons"] as? [[String: Any]] else { continue }
                for season in seasons {
                    guard let number = season["number"] as? Int, let episodes = season["episodes"] as? [[String: Any]] else { continue }
                    for episode in episodes {
                        guard let episodeNumber = episode["number"] as? Int,
                              let media = Self.episode(show: show, season: number, number: episodeNumber) else { continue }
                        remoteWatched.insert(media.identity)
                        let at = Self.date(episode["last_watched_at"]) ?? .distantPast
                        for key in index.keys(for: media) {
                            if markWatched(key: key, at: at, index: index, context: context) { marked += 1 }
                        }
                    }
                }
            }
            try? context.save()

            // Local "watched" that Trakt does not have yet.
            let entries = (try? context.fetch(FetchDescriptor<MediaEntry>())) ?? []
            let missing = entries.filter(\.isWatched).compactMap { index.media[$0.key] }.filter { !remoteWatched.contains($0.identity) }
            if !missing.isEmpty { setWatched(true, media: Array(Set(missing))) }

            status = "Đã đồng bộ: \(resumed) điểm xem tiếp, \(marked) mục đã xem" + (missing.isEmpty ? "" : ", gửi \(missing.count) lên Trakt")
        } catch {
            status = error.localizedDescription
        }
    }

    /// Takes Trakt's resume point when it is newer than what this device saved.
    private func applyResume(key: String, progress: Double, at pausedAt: Date, index: TraktLibraryIndex, context: ModelContext) -> Bool {
        let entry = MediaLibrary.entry(forKey: key, in: context)
        if let entry, entry.lastPlayedAt >= pausedAt { return false }
        let duration = (entry?.duration ?? 0) > 1 ? entry!.duration : Double(index.runtime[key] ?? 0) * 60
        guard duration > 0 else { return false }
        let target = entry ?? MediaLibrary.makeEntry(key: key, title: index.titles[key] ?? key, in: context)
        target.duration = duration
        target.position = duration * min(1, max(0, progress / 100))
        target.lastPlayedAt = pausedAt
        return true
    }

    private func markWatched(key: String, at watchedAt: Date, index: TraktLibraryIndex, context: ModelContext) -> Bool {
        let entry = MediaLibrary.entry(forKey: key, in: context)
        if let entry, entry.isWatched || entry.lastPlayedAt > watchedAt { return false }
        let target = entry ?? MediaLibrary.makeEntry(key: key, title: index.titles[key] ?? key, in: context)
        if target.duration <= 0 { target.duration = max(1, Double(index.runtime[key] ?? 0) * 60) }
        target.position = target.duration
        target.lastPlayedAt = watchedAt
        return true
    }

    // MARK: Parsing

    private static func media(from item: [String: Any]) -> TraktMedia? {
        if let movie = item["movie"] as? [String: Any] { return Self.movie(movie) }
        if let show = item["show"] as? [String: Any], let episode = item["episode"] as? [String: Any],
           let season = episode["season"] as? Int, let number = episode["number"] as? Int {
            return Self.episode(show: show, season: season, number: number)
        }
        return nil
    }

    private static func movie(_ object: [String: Any]) -> TraktMedia? {
        guard let title = object["title"] as? String else { return nil }
        let ids = object["ids"] as? [String: Any]
        return .movie(title: title, year: object["year"] as? Int, tmdb: ids?["tmdb"] as? Int)
    }

    private static func episode(show: [String: Any], season: Int, number: Int) -> TraktMedia? {
        guard let title = show["title"] as? String else { return nil }
        let ids = show["ids"] as? [String: Any]
        return .episode(show: title, year: show["year"] as? Int, tmdb: ids?["tmdb"] as? Int, season: season, number: number)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: HTTP

    private enum TraktError: LocalizedError {
        case http(Int)
        case message(String)

        var errorDescription: String? {
            switch self {
            case .http(401): return "Trakt: phiên đăng nhập hết hạn — kết nối lại."
            case .http(403): return "Trakt từ chối Client ID (403) — kiểm tra lại ứng dụng Trakt."
            case .http(400): return "Trakt từ chối yêu cầu (400) — nếu ứng dụng Trakt không có Client Secret, hãy xoá ô Client Secret."
            case let .http(code): return "Trakt lỗi \(code)."
            case let .message(text): return text
            }
        }
    }

    private func loadUsername() async {
        guard let settings = try? await getObject("/users/settings"),
              let user = settings["user"] as? [String: Any], let name = user["username"] as? String else { return }
        username = name
        UserDefaults.standard.set(name, forKey: Self.usernameKey)
    }

    private func store(_ body: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw TraktError.message("Trakt trả token không hợp lệ.")
        }
        let created = (json["created_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .now
        let token = Token(access: access, refresh: refresh, expires: created.addingTimeInterval(json["expires_in"] as? Double ?? 7_776_000))
        self.token = token
        if let data = try? JSONEncoder().encode(token) { Keychain.set(String(decoding: data, as: UTF8.self), account: Self.tokenAccount) }
    }

    /// Older Trakt apps have a client secret; PKCE apps (no secret) must not send one ("invalid_client").
    private static func withSecret(_ body: [String: Any], _ secret: String?) -> [String: Any] {
        guard let secret else { return body }
        var body = body
        body["client_secret"] = secret
        return body
    }

    /// Redirect URIs a Trakt app may be registered with: new (Development) apps only accept localhost, older
    /// apps used the out-of-band URN. The refresh request must name the registered one.
    private static let redirectURIs = ["http://localhost", "http://127.0.0.1", "urn:ietf:wg:oauth:2.0:oob"]

    /// Refreshes the access token when less than an hour is left (also once it has expired: the refresh token
    /// stays valid), so short-lived tokens are not renewed on every request.
    private func validAccessToken() async throws -> String {
        guard let token else { throw TraktError.http(401) }
        guard token.expires.timeIntervalSinceNow < 3_600, let client = AppSettings.traktClient else { return token.access }
        var status = 0
        for redirect in Self.redirectURIs {
            let (code, body) = try await raw("/oauth/token", method: "POST", body: Self.withSecret([
                "refresh_token": token.refresh, "client_id": client.id,
                "redirect_uri": redirect, "grant_type": "refresh_token",
            ], client.secret), authorized: false)
            if code == 200 {
                try store(body)
                return self.token?.access ?? token.access
            }
            status = code
            // 400 / 401 can mean a redirect URI the app was not registered with: try the next one.
            guard code == 400 || code == 401 else { break }
        }
        if status == 401 || status == 400 { disconnect() }
        throw TraktError.http(status)
    }

    private func getList(_ path: String) async throws -> [[String: Any]] {
        let (status, body) = try await raw(path, method: "GET", body: nil, authorized: true)
        guard status == 200 else { throw TraktError.http(status) }
        return (try JSONSerialization.jsonObject(with: body) as? [[String: Any]]) ?? []
    }

    private func getObject(_ path: String) async throws -> [String: Any] {
        let (status, body) = try await raw(path, method: "GET", body: nil, authorized: true)
        guard status == 200 else { throw TraktError.http(status) }
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    private func post(_ path: String, _ body: [String: Any], authorized: Bool) async throws -> [String: Any] {
        let (status, data) = try await raw(path, method: "POST", body: body, authorized: authorized)
        guard (200...299).contains(status) else { throw TraktError.http(status) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func raw(_ path: String, method: String, body: [String: Any]?, authorized: Bool) async throws -> (Int, Data) {
        guard let client = AppSettings.traktClient, let url = URL(string: Self.api + path) else { throw TraktError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(client.id, forHTTPHeaderField: "trakt-api-key")
        request.setValue("XT-Player/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        if authorized { request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// The library seen from Trakt: which file keys a Trakt movie / episode is, plus titles and runtimes.
@MainActor
struct TraktLibraryIndex {
    private(set) var byIdentity: [String: [String]] = [:]
    /// file key → Trakt media (for pushing local "watched").
    private(set) var media: [String: TraktMedia] = [:]
    private(set) var titles: [String: String] = [:]
    /// file key → minutes.
    private(set) var runtime: [String: Int] = [:]

    static func build(context: ModelContext) -> TraktLibraryIndex {
        var index = TraktLibraryIndex()
        let items = Dictionary(((try? context.fetch(FetchDescriptor<LibraryItem>())) ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for file in (try? context.fetch(FetchDescriptor<LibraryFile>())) ?? [] {
            guard let item = items[file.itemKey] else { continue }
            var forms: [TraktMedia] = []
            if item.kind == .show, let season = file.season, let episode = file.episode {
                forms.append(.episode(show: item.title, year: item.year, tmdb: item.tmdbID, season: season, number: episode))
                if item.tmdbID != nil { forms.append(.episode(show: item.title, year: item.year, tmdb: nil, season: season, number: episode)) }
            } else if item.kind == .movie {
                forms.append(.movie(title: item.title, year: item.year, tmdb: item.tmdbID))
                if item.tmdbID != nil { forms.append(.movie(title: item.title, year: item.year, tmdb: nil)) }
            }
            guard let primary = forms.first else { continue }
            if item.tmdbID != nil || item.year != nil || item.kind == .show { index.media[file.key] = primary }
            for form in forms { index.byIdentity[form.identity, default: []].append(file.key) }
            index.titles[file.key] = item.title
            if let minutes = item.runtime { index.runtime[file.key] = minutes }
        }
        return index
    }

    /// Library files for a Trakt item: by TMDb id first, then by title and year.
    func keys(for media: TraktMedia) -> [String] {
        if let keys = byIdentity[media.identity], !keys.isEmpty { return keys }
        switch media {
        case let .movie(title, year, tmdb?) where tmdb > 0:
            return byIdentity[TraktMedia.movie(title: title, year: year, tmdb: nil).identity] ?? []
        case let .episode(show, year, tmdb?, season, number) where tmdb > 0:
            return byIdentity[TraktMedia.episode(show: show, year: year, tmdb: nil, season: season, number: number).identity] ?? []
        default:
            return []
        }
    }
}
