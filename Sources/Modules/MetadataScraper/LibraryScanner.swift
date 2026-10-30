import Foundation
import SwiftData

/// Walks library folders on a server, recognises movies / episodes from file and folder names,
/// enriches them from TMDb and upserts `LibraryItem` / `LibraryFile` rows.
@MainActor
final class LibraryScanner: ObservableObject {
    @Published private(set) var isScanning = false
    @Published private(set) var status = ""
    @Published private(set) var lastError: String?
    private var isGeneratingArtwork = false

    private static let skippedFolders: Set<String> = [
        "@eadir", "#recycle", "#snapshot", ".snapshots", "$recycle.bin", "system volume information",
        "extras", "featurettes", "behind the scenes", "deleted scenes", "trailers", "sample", "samples", "other", "interviews",
    ]
    private static let maxDepth = 7

    struct Found {
        let item: RemoteItem
        let parentName: String
        let subtitles: [String]
    }

    /// Scans every library folder of every server.
    func scanAll(context: ModelContext) async {
        let folders = (try? context.fetch(FetchDescriptor<LibraryFolder>())) ?? []
        for folder in folders {
            await scan(folder: folder, context: context)
        }
    }

    func scan(folder: LibraryFolder, context: ModelContext) async {
        guard !isScanning else { return }
        let serverID = folder.serverID
        var descriptor = FetchDescriptor<MediaServer>(predicate: #Predicate { $0.id == serverID })
        descriptor.fetchLimit = 1
        guard let server = try? context.fetch(descriptor).first else { return }
        let credentials = server.credentials
        isScanning = true
        lastError = nil
        status = "Đang quét \(folder.name)…"
        defer { isScanning = false }

        let fs = RemoteFileSystems.make(credentials)
        let found: [Found]
        do {
            found = try await Self.collect(fs: fs, root: folder.path) { [weak self] count in
                self?.status = "Đang quét \(folder.name): \(count) tệp…"
            }
        } catch {
            await fs.close()
            lastError = error.localizedDescription
            status = ""
            return
        }
        await fs.close()

        let tmdb = TMDbClient.current()
        var showCache: [String: LibraryItem] = [:]
        var movieCache: [String: LibraryItem] = [:]
        var seenKeys = Set<String>()
        for (index, entry) in found.enumerated() {
            status = "Nhận diện \(index + 1)/\(found.count)…"
            let parsed = Self.recognise(fileName: entry.item.name, parentFolder: entry.parentName)
            let fileKey = RemoteFileSystems.key(server: credentials, path: entry.item.path)
            seenKeys.insert(fileKey)

            let item: LibraryItem
            switch parsed.kind {
            case .episode:
                let cacheKey = parsed.title.lowercased()
                if let cached = showCache[cacheKey] {
                    item = cached
                } else {
                    item = await upsertItem(kind: .show, parsed: parsed, tmdb: tmdb, context: context)
                    showCache[cacheKey] = item
                }
            case .movie:
                let cacheKey = "\(parsed.title.lowercased())|\(parsed.year ?? 0)"
                if let cached = movieCache[cacheKey] {
                    item = cached
                } else {
                    item = await upsertItem(kind: .movie, parsed: parsed, tmdb: tmdb, context: context)
                    movieCache[cacheKey] = item
                }
            }

            let file = existingFile(key: fileKey, context: context) ?? {
                let f = LibraryFile(key: fileKey, itemKey: item.key, folderKey: folder.key, serverID: credentials.id,
                                    path: entry.item.path, fileName: entry.item.name, size: entry.item.size)
                context.insert(f)
                return f
            }()
            file.itemKey = item.key
            file.size = entry.item.size
            file.subtitlePaths = entry.subtitles
            file.badges = parsed.badges
            if case let .episode(season, episode) = parsed.kind {
                file.season = season
                file.episode = episode
            }
        }

        // Episode titles and stills, one TMDb request per season.
        if let tmdb {
            for show in showCache.values {
                guard let id = show.tmdbID else { continue }
                let showKey = show.key
                let files = (try? context.fetch(FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.itemKey == showKey }))) ?? []
                let seasons = Set(files.compactMap(\.season))
                for number in seasons.sorted() {
                    status = "Tải thông tin \(show.title) mùa \(number)…"
                    guard let season = try? await tmdb.season(show: id, number: number) else { continue }
                    let byEpisode = Dictionary(season.episodes.map { ($0.episodeNumber, $0) }, uniquingKeysWith: { a, _ in a })
                    for file in files where file.season == number {
                        guard let episode = file.episode, let info = byEpisode[episode] else { continue }
                        file.episodeTitle = info.name
                        file.episodeOverview = info.overview
                        file.stillPath = info.stillPath
                        file.airDate = info.airDate
                    }
                }
            }
        }

        // Files that disappeared from this folder.
        let folderKey = folder.key
        let stale = (try? context.fetch(FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.folderKey == folderKey }))) ?? []
        for file in stale where !seenKeys.contains(file.key) {
            context.delete(file)
        }
        removeOrphanItems(context: context)

        folder.lastScan = .now
        folder.fileCount = found.count
        try? context.save()
        status = "Đã quét \(found.count) tệp trong \(folder.name)"
        Task { await generateMissingArtwork(context: context) }
    }

    /// Items without TMDb artwork (home videos, concerts, unmatched titles) and Continue Watching entries
    /// without a picture get a frame of their video, as Infuse does. Runs after each scan and once at launch.
    func generateMissingArtwork(context: ModelContext) async {
        guard !isGeneratingArtwork else { return }
        isGeneratingArtwork = true
        defer { isGeneratingArtwork = false }

        let items = ((try? context.fetch(FetchDescriptor<LibraryItem>())) ?? [])
            .filter { !ThumbnailStore.isUsable($0.posterPath) && !ThumbnailStore.isUsable($0.backdropPath) }
        let filesByItem = Dictionary(grouping: (try? context.fetch(FetchDescriptor<LibraryFile>())) ?? [], by: \.itemKey)
        let servers = Dictionary(((try? context.fetch(FetchDescriptor<MediaServer>())) ?? []).map { ($0.id, $0.credentials) },
                                 uniquingKeysWith: { first, _ in first })
        let entries = Dictionary(((try? context.fetch(FetchDescriptor<MediaEntry>())) ?? []).map { ($0.key, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let previousStatus = status

        for (index, item) in items.enumerated() {
            let files = (filesByItem[item.key] ?? []).sorted { ($0.season ?? 0, $0.episode ?? 0, $0.path) < ($1.season ?? 0, $1.episode ?? 0, $1.path) }
            guard let file = files.first, let serverID = file.serverID, let server = servers[serverID],
                  let url = RemoteFileSystems.playbackURL(server: server, path: file.path) else { continue }
            let reference = ThumbnailStore.reference(forKey: file.key)
            guard let output = ThumbnailStore.url(for: reference) else { continue }
            if !FileManager.default.fileExists(atPath: output.path) {
                status = "Tạo ảnh bìa \(index + 1)/\(items.count)…"
                RemoteCredentialStore.shared.register(server)
                let location = url.absoluteString
                guard let probe = await Task.detached(priority: .utility, operation: { FrameGrabber.grab(location, to: output) }).value
                else { continue }
                MediaLibrary.learn(fileKey: file.key, resolution: probe.resolutionLabel, duration: probe.duration, in: context)
            }
            item.posterPath = reference
            item.backdropPath = reference
            for file in files {
                if let entry = entries[file.key], entry.artworkPath == nil { entry.artworkPath = reference }
            }
            try? context.save()
        }

        // Continue Watching entries opened straight from a share (not part of the library).
        for entry in entries.values where entry.artworkPath == nil && entry.urlString.hasPrefix("xtsmb:") {
            guard let serverID = entry.serverID, let server = servers[serverID] else { continue }
            let reference = ThumbnailStore.reference(forKey: entry.key)
            guard let output = ThumbnailStore.url(for: reference) else { continue }
            if !FileManager.default.fileExists(atPath: output.path) {
                RemoteCredentialStore.shared.register(server)
                let location = entry.urlString
                guard await Task.detached(priority: .utility, operation: { FrameGrabber.grab(location, to: output) }).value != nil
                else { continue }
            }
            entry.artworkPath = reference
            try? context.save()
        }
        status = previousStatus
    }

    /// Re-fetch TMDb metadata for one item (e.g. after a wrong match or adding a key).
    func refresh(_ item: LibraryItem, context: ModelContext) async {
        guard let tmdb = TMDbClient.current() else { return }
        let parsed = ParsedMediaName(title: item.title, year: item.year, kind: item.kind == .show ? .episode(season: 1, episode: 1) : .movie,
                                     resolution: nil, dynamicRange: [], audio: [])
        item.tmdbID = nil
        await enrich(item, parsed: parsed, tmdb: tmdb)
        try? context.save()
    }

    // MARK: - Recognition

    static func recognise(fileName: String, parentFolder: String) -> ParsedMediaName {
        var parsed = FilenameParser.parse(fileName)
        if case .movie = parsed.kind {
            let folder = FilenameParser.parse(parentFolder)
            let weakName = parsed.title.count < 3 || ["movie", "video", "main", "feature", "film"].contains(parsed.title.lowercased())
            // "Dune (2021)/dune.2160p.mkv": the folder carries the canonical title + year.
            if weakName || (parsed.year == nil && folder.year != nil) {
                parsed.title = folder.title
                parsed.year = folder.year ?? parsed.year
            }
        }
        if case .episode = parsed.kind, parsed.title.isEmpty || parsed.title.lowercased().hasPrefix("season") {
            parsed.title = FilenameParser.parse(parentFolder).title
        }
        return parsed
    }

    private static func collect(fs: RemoteFileSystem, root: String, progress: @escaping (Int) -> Void) async throws -> [Found] {
        var results: [Found] = []
        var queue: [(path: String, depth: Int, name: String)] = [(root, 0, (root as NSString).lastPathComponent)]
        var showFolderName: [String: String] = [:]
        while !queue.isEmpty {
            let (path, depth, name) = queue.removeFirst()
            let items: [RemoteItem]
            do {
                items = try await fs.list(path)
            } catch {
                if depth == 0 { throw error }
                continue
            }
            let subtitles = items.filter(\.isSubtitle)
            let videos = items.filter(\.isVideo)
            // A "Season 01" folder inherits its show's name.
            let parent = name.lowercased().hasPrefix("season") || name.lowercased().hasPrefix("mùa")
                ? (showFolderName[path] ?? name) : name
            for video in videos {
                let base = video.baseName.lowercased()
                var matched = subtitles.filter { $0.baseName.lowercased().hasPrefix(base) }
                if matched.isEmpty, videos.count == 1 { matched = subtitles }
                results.append(Found(item: video, parentName: parent, subtitles: matched.map(\.path)))
            }
            progress(results.count)
            guard depth < maxDepth else { continue }
            for dir in items where dir.isDirectory && !skippedFolders.contains(dir.name.lowercased()) {
                showFolderName[dir.path] = parent
                queue.append((dir.path, depth + 1, dir.name))
            }
        }
        return results
    }

    // MARK: - Persistence

    private func existingFile(key: String, context: ModelContext) -> LibraryFile? {
        var d = FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func upsertItem(kind: LibraryKind, parsed: ParsedMediaName, tmdb: TMDbClient?, context: ModelContext) async -> LibraryItem {
        let localKey = "local:\(kind.rawValue):\(parsed.title.lowercased())|\(kind == .movie ? parsed.year ?? 0 : 0)"
        var d = FetchDescriptor<LibraryItem>(predicate: #Predicate { $0.key == localKey })
        d.fetchLimit = 1
        if let existing = try? context.fetch(d).first {
            if existing.tmdbID == nil, let tmdb { await enrich(existing, parsed: parsed, tmdb: tmdb) }
            return existing
        }
        let item = LibraryItem(key: localKey, kind: kind, title: parsed.title, year: parsed.year)
        context.insert(item)
        if let tmdb { await enrich(item, parsed: parsed, tmdb: tmdb) }
        return item
    }

    private func enrich(_ item: LibraryItem, parsed: ParsedMediaName, tmdb: TMDbClient) async {
        do {
            let hit: TMDbSearchResult?
            let details: TMDbDetails?
            if item.kind == .movie {
                hit = try await tmdb.searchMovie(parsed.title, year: parsed.year)
                details = try await hit.asyncMap { try await tmdb.movie($0.id) }
            } else {
                hit = try await tmdb.searchShow(parsed.title, year: nil)
                details = try await hit.asyncMap { try await tmdb.show($0.id) }
            }
            guard let details else { return }
            item.tmdbID = details.id
            item.title = details.displayTitle ?? item.title
            item.originalTitle = details.originalTitle ?? details.originalName
            item.year = details.year ?? item.year
            item.overview = details.overview
            item.tagline = details.tagline
            item.posterPath = details.posterPath
            item.backdropPath = details.backdropPath
            item.rating = details.voteAverage
            item.runtime = details.runtime ?? details.episodeRunTime?.first
            item.genres = details.genres?.map(\.name) ?? []
            item.cast = (details.credits?.cast ?? []).prefix(15).map { "\($0.name)|\($0.character ?? "")|\($0.profilePath ?? "")" }
            item.updatedAt = .now
        } catch {
            lastError = "TMDb: \(error.localizedDescription)"
        }
    }

    private func removeOrphanItems(context: ModelContext) {
        let files = (try? context.fetch(FetchDescriptor<LibraryFile>())) ?? []
        let used = Set(files.map(\.itemKey))
        let items = (try? context.fetch(FetchDescriptor<LibraryItem>())) ?? []
        for item in items where !used.contains(item.key) {
            context.delete(item)
        }
    }
}

private extension Optional {
    func asyncMap<U>(_ transform: (Wrapped) async throws -> U) async rethrows -> U? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
