import Foundation
import SwiftData

/// Walks library folders on a server, recognises movies / episodes from file and folder names,
/// enriches them from TMDb (or Trakt when no TMDb key is set) and upserts `LibraryItem` / `LibraryFile` rows.
@MainActor
final class LibraryScanner: ObservableObject {
    @Published private(set) var isScanning = false
    @Published private(set) var status = ""
    @Published private(set) var lastError: String?
    private var isGeneratingArtwork = false
    /// Library item key → Trakt show id, from Trakt matches (episode titles and stills).
    private var traktShowIDs: [String: Int] = [:]
    private static let traktIdentifiedKey = "library.traktIdentified"

    private static let skippedFolders: Set<String> = [
        "@eadir", "#recycle", "#snapshot", ".snapshots", "$recycle.bin", "system volume information",
        "extras", "featurettes", "behind the scenes", "deleted scenes", "trailers", "sample", "samples", "other", "interviews",
    ]
    private static let maxDepth = 7

    struct Found {
        let item: RemoteItem
        let parentName: String
        let subtitles: [String]
        /// Folder holding the file, its name's parent folder (album artist), and a cover image next to it.
        var directory = ""
        var directoryParent: String?
        var cover: RemoteItem?
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

        let kind = LibraryFolderKind.of(folder.key)
        let fs = RemoteFileSystems.make(credentials)
        let found: [Found]
        do {
            found = try await Self.collect(fs: fs, root: folder.path, audio: kind == .music) { [weak self] count in
                self?.status = "Đang quét \(folder.name): \(count) tệp…"
            }
        } catch {
            await fs.close()
            lastError = error.localizedDescription
            status = ""
            return
        }

        var seenKeys = Set<String>()
        switch kind {
        case .films:
            await fs.close()
            await recogniseFilms(found, folder: folder, credentials: credentials, seenKeys: &seenKeys, context: context)
        case .musicVideos:
            await fs.close()
            recogniseMusicVideos(found, folder: folder, credentials: credentials, seenKeys: &seenKeys, context: context)
        case .music:
            await recogniseAlbums(found, fs: fs, folder: folder, credentials: credentials, seenKeys: &seenKeys, context: context)
            await fs.close()
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

    /// Movies and episodes: recognised from names, enriched from TMDb (or Trakt without a TMDb key).
    private func recogniseFilms(_ found: [Found], folder: LibraryFolder, credentials: ServerCredentials,
                                seenKeys: inout Set<String>, context: ModelContext) async {
        let tmdb = TMDbClient.current()
        let trakt = tmdb == nil ? TraktMetadata.current() : nil
        var showCache: [String: LibraryItem] = [:]
        var movieCache: [String: LibraryItem] = [:]
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
                    item = await upsertItem(kind: .show, parsed: parsed, tmdb: tmdb, trakt: trakt, context: context)
                    showCache[cacheKey] = item
                }
            case .movie:
                let cacheKey = "\(parsed.title.lowercased())|\(parsed.year ?? 0)"
                if let cached = movieCache[cacheKey] {
                    item = cached
                } else {
                    item = await upsertItem(kind: .movie, parsed: parsed, tmdb: tmdb, trakt: trakt, context: context)
                    movieCache[cacheKey] = item
                }
            }

            let file = libraryFile(for: entry, key: fileKey, item: item, folder: folder, credentials: credentials, context: context)
            file.subtitlePaths = entry.subtitles
            file.badges = parsed.badges
            if case let .episode(season, episode) = parsed.kind {
                file.season = season
                file.episode = episode
            }
        }
        await fillEpisodes(of: Array(showCache.values), tmdb: tmdb, trakt: trakt, context: context)
    }

    /// One item per file, titled from its name, artist / show from its folder; no TMDb or Trakt lookup (a concert
    /// would otherwise turn into an unrelated film). Artwork is a frame of the video.
    private func recogniseMusicVideos(_ found: [Found], folder: LibraryFolder, credentials: ServerCredentials,
                                      seenKeys: inout Set<String>, context: ModelContext) {
        for (index, entry) in found.enumerated() {
            status = "Nhận diện \(index + 1)/\(found.count)…"
            let fileKey = RemoteFileSystems.key(server: credentials, path: entry.item.path)
            seenKeys.insert(fileKey)
            let parsed = FilenameParser.parse(entry.item.name)
            let title = parsed.title.count >= 2 ? parsed.title : entry.item.baseName
            let item = plainItem(key: "musicvideo:\(fileKey)", kind: .musicVideo, title: title, context: context)
            item.year = parsed.year ?? item.year
            item.tagline = entry.parentName == folder.name ? nil : entry.parentName
            let file = libraryFile(for: entry, key: fileKey, item: item, folder: folder, credentials: credentials, context: context)
            file.subtitlePaths = entry.subtitles
            file.badges = parsed.badges
        }
    }

    /// One album per folder of tracks ("CD1" / "Disc 2" folders join their parent). The album artist is the folder
    /// above, or the part before " - " in "Artist - Album"; the cover is cover / folder / front.jpg next to the
    /// tracks, else the picture embedded in the first track (see generateMissingArtwork).
    private func recogniseAlbums(_ found: [Found], fs: RemoteFileSystem, folder: LibraryFolder, credentials: ServerCredentials,
                                 seenKeys: inout Set<String>, context: ModelContext) async {
        var albums: [String: LibraryItem] = [:]
        var covers: [String: RemoteItem] = [:]
        for (index, entry) in found.enumerated() {
            status = "Nhận diện \(index + 1)/\(found.count)…"
            let fileKey = RemoteFileSystems.key(server: credentials, path: entry.item.path)
            seenKeys.insert(fileKey)

            var albumPath = entry.directory
            var albumName = entry.parentName
            var artistName = entry.directoryParent
            var disc: Int?
            if let number = Self.discNumber(albumName), let parent = entry.directoryParent {
                disc = number
                albumPath = (albumPath as NSString).deletingLastPathComponent
                albumName = parent
                artistName = nil
            }
            let parsedAlbum = Self.albumTitle(albumName)
            let key = "album:\(credentials.id):\(albumPath)"
            let album = albums[key] ?? plainItem(key: key, kind: .album, title: parsedAlbum.title, context: context)
            albums[key] = album
            album.title = parsedAlbum.title
            album.year = parsedAlbum.year ?? album.year
            album.tagline = parsedAlbum.artist ?? (artistName == folder.name ? nil : artistName)
            if covers[key] == nil, let cover = entry.cover { covers[key] = cover }

            let track = FilenameParser.track(entry.item.name)
            let file = libraryFile(for: entry, key: fileKey, item: album, folder: folder, credentials: credentials, context: context)
            file.season = disc ?? track.disc
            file.episode = track.number
            file.episodeTitle = track.title
            file.badges = [MediaTrack.prettyCodec(entry.item.fileExtension == "dff" ? "dsd" : Self.codecName(entry.item.fileExtension))]
        }

        for (key, cover) in covers {
            guard let album = albums[key], !ThumbnailStore.isUsable(album.posterPath),
                  let output = ThumbnailStore.url(for: ThumbnailStore.reference(forKey: "cover:" + key)),
                  let data = try? await fs.download(cover.path), !data.isEmpty else { continue }
            try? FileManager.default.createDirectory(at: ThumbnailStore.directory, withIntermediateDirectories: true)
            guard (try? data.write(to: output)) != nil else { continue }
            album.posterPath = ThumbnailStore.reference(forKey: "cover:" + key)
            album.backdropPath = album.posterPath
        }
    }

    /// "CD1", "CD 2", "Disc 3", "Disk 1" → disc number.
    private static func discNumber(_ name: String) -> Int? {
        let folded = name.lowercased().replacingOccurrences(of: " ", with: "")
        for prefix in ["cd", "disc", "disk"] where folded.hasPrefix(prefix) {
            return Int(folded.dropFirst(prefix.count))
        }
        return nil
    }

    /// "Artist - Album (2019) [FLAC 24-96]" → artist, album, year.
    private static func albumTitle(_ name: String) -> (artist: String?, title: String, year: Int?) {
        var title = name.replacingOccurrences(of: "_", with: " ")
        var year: Int?
        if let regex = try? NSRegularExpression(pattern: #"[\(\[]((?:19|20)\d{2})[\)\]]"#),
           let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let range = Range(match.range(at: 1), in: title) {
            year = Int(title[range])
        }
        // Drop bracketed tags: years, formats, bit depths.
        title = title.replacingOccurrences(of: #"\s*[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: "", options: .regularExpression)
        var artist: String?
        let parts = title.components(separatedBy: " - ")
        if parts.count >= 2, let first = parts.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty {
            if let leadingYear = Int(first), (1900...2100).contains(leadingYear) {
                year = year ?? leadingYear
            } else {
                artist = first
            }
            title = parts.dropFirst().joined(separator: " - ")
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return (artist, title.isEmpty ? name : title, year)
    }

    private static func codecName(_ fileExtension: String) -> String {
        switch fileExtension {
        case "dsf", "dff": return "dsd"
        case "wv": return "wavpack"
        case "m4a", "alac": return "alac"
        case "aif", "aiff", "aifc", "wav", "w64": return "pcm_" + fileExtension
        case "thd", "truehd": return "truehd"
        case "dtshd": return "dts"
        case "ec3": return "eac3"
        case "oga", "ogg": return "vorbis"
        case "mpc": return "mpc8"
        default: return fileExtension
        }
    }

    private func plainItem(key: String, kind: LibraryKind, title: String, context: ModelContext) -> LibraryItem {
        var descriptor = FetchDescriptor<LibraryItem>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.kindRaw = kind.rawValue
            return existing
        }
        let item = LibraryItem(key: key, kind: kind, title: title, year: nil)
        context.insert(item)
        return item
    }

    private func libraryFile(for entry: Found, key: String, item: LibraryItem, folder: LibraryFolder,
                             credentials: ServerCredentials, context: ModelContext) -> LibraryFile {
        let file = existingFile(key: key, context: context) ?? {
            let f = LibraryFile(key: key, itemKey: item.key, folderKey: folder.key, serverID: credentials.id,
                                path: entry.item.path, fileName: entry.item.name, size: entry.item.size)
            context.insert(f)
            return f
        }()
        file.itemKey = item.key
        file.folderKey = folder.key
        file.size = entry.item.size
        return file
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
        // A server that cannot be read right now (asleep, network not back after a wake) is not asked again in
        // this pass: every file would wait for the timeout and then be taken for a file without a picture.
        var unreachable: Set<String> = []

        for (index, item) in items.enumerated() {
            let files = (filesByItem[item.key] ?? []).sorted { ($0.season ?? 0, $0.episode ?? 0, $0.path) < ($1.season ?? 0, $1.episode ?? 0, $1.path) }
            guard let file = files.first, let serverID = file.serverID, !unreachable.contains(serverID), let server = servers[serverID],
                  let url = RemoteFileSystems.playbackURL(server: server, path: file.path) else { continue }
            let reference = ThumbnailStore.reference(forKey: file.key)
            guard let output = ThumbnailStore.url(for: reference) else { continue }
            if !FileManager.default.fileExists(atPath: output.path) {
                // Tracks without an embedded picture (and broken files) are not retried at every launch.
                guard !ThumbnailStore.recentlyFailed(file.key) else { continue }
                status = "Tạo ảnh bìa \(index + 1)/\(items.count)…"
                RemoteCredentialStore.shared.register(server)
                let location = url.absoluteString
                // An album's picture is the cover embedded in its first track (shown by mpv as a still frame).
                let fraction = item.kind == .album ? 0.0 : 0.2
                let probe: FrameGrabber.Probe
                switch await Task.detached(priority: .utility, operation: { FrameGrabber.grab(location, to: output, at: fraction) }).value {
                case let .success(result):
                    probe = result
                case .failure(.noPicture):
                    ThumbnailStore.markFailed(file.key)
                    continue
                case .failure(.unavailable):
                    unreachable.insert(serverID)
                    continue
                }
                if item.kind != .album {
                    MediaLibrary.learn(fileKey: file.key, resolution: probe.resolutionLabel, duration: probe.duration, in: context)
                }
            }
            item.posterPath = reference
            item.backdropPath = reference
            for file in files {
                if let entry = entries[file.key], entry.artworkPath == nil { entry.artworkPath = reference }
            }
            try? context.save()
        }

        // Continue Watching entries that are not library files: opened from a share, from WebDAV, or a file on
        // this device (read through its security-scoped bookmark).
        for entry in entries.values where entry.artworkPath == nil {
            guard let source = Self.grabSource(for: entry, servers: servers) else { continue }
            let reference = ThumbnailStore.reference(forKey: entry.key)
            guard let output = ThumbnailStore.url(for: reference) else { continue }
            if !FileManager.default.fileExists(atPath: output.path) {
                let scoped = source.scoped?.startAccessingSecurityScopedResource() ?? false
                let location = source.location
                let result = await Task.detached(priority: .utility, operation: { FrameGrabber.grab(location, to: output) }).value
                if scoped { source.scoped?.stopAccessingSecurityScopedResource() }
                guard case .success = result else { continue }
            }
            entry.artworkPath = reference
            try? context.save()
        }
        status = previousStatus
    }

    /// Where mpv can read a Continue Watching entry from, and the security-scoped URL to unlock for local files.
    private static func grabSource(for entry: MediaEntry, servers: [String: ServerCredentials]) -> (location: String, scoped: URL?)? {
        if entry.urlString.hasPrefix("xtsmb:") {
            guard let id = entry.serverID, let server = servers[id] else { return nil }
            RemoteCredentialStore.shared.register(server)
            return (entry.urlString, nil)
        }
        if entry.isLocalFile {
            if let bookmark = entry.bookmark, let source = MediaSource.restore(urlString: entry.urlString, bookmark: bookmark),
               source.url.isFileURL {
                return (source.url.path, source.url)
            }
            return FileManager.default.isReadableFile(atPath: entry.urlString) ? (entry.urlString, nil) : nil
        }
        // WebDAV: the stored URL has no credentials; rebuild the playback URL from the server.
        if let id = entry.serverID, let server = servers[id], server.kind == .webdav, let url = URL(string: entry.urlString),
           let playback = RemoteFileSystems.playbackURL(server: server, path: url.path) {
            return (playback.absoluteString, nil)
        }
        return nil
    }

    /// Re-fetch metadata for one item (e.g. after a wrong match or adding a key).
    func refresh(_ item: LibraryItem, context: ModelContext) async {
        let tmdb = TMDbClient.current()
        let trakt = tmdb == nil ? TraktMetadata.current() : nil
        guard tmdb != nil || trakt != nil else { return }
        item.tmdbID = nil
        await enrich(item, parsed: Self.parsed(item), tmdb: tmdb, trakt: trakt)
        try? context.save()
    }

    /// Without a TMDb key, items scanned earlier (before Trakt recognition existed) are looked up on Trakt
    /// once, at launch; titles Trakt does not know (concerts, home videos) are not asked about again.
    func identifyUnmatched(context: ModelContext) async {
        guard !isScanning, TMDbClient.current() == nil, let trakt = TraktMetadata.current() else { return }
        var attempted = Set(UserDefaults.standard.stringArray(forKey: Self.traktIdentifiedKey) ?? [])
        let items = ((try? context.fetch(FetchDescriptor<LibraryItem>())) ?? []).filter {
            ($0.kind == .movie || $0.kind == .show) && $0.tmdbID == nil && !attempted.contains($0.key)
        }
        guard !items.isEmpty else { return }
        isScanning = true
        defer { isScanning = false }
        for (index, item) in items.enumerated() {
            status = "Nhận diện qua Trakt \(index + 1)/\(items.count)…"
            await enrich(item, parsed: Self.parsed(item), tmdb: nil, trakt: trakt)
            attempted.insert(item.key)
        }
        UserDefaults.standard.set(Array(attempted), forKey: Self.traktIdentifiedKey)
        await fillEpisodes(of: items.filter { $0.kind == .show && $0.tmdbID != nil }, tmdb: nil, trakt: trakt, context: context)
        try? context.save()
        status = ""
    }

    private static func parsed(_ item: LibraryItem) -> ParsedMediaName {
        ParsedMediaName(title: item.title, year: item.year, kind: item.kind == .show ? .episode(season: 1, episode: 1) : .movie,
                        resolution: nil, dynamicRange: [], audio: [])
    }

    /// Episode titles, overviews and stills, one request per season.
    private func fillEpisodes(of shows: [LibraryItem], tmdb: TMDbClient?, trakt: TraktMetadata?, context: ModelContext) async {
        guard tmdb != nil || trakt != nil else { return }
        for show in shows {
            let showKey = show.key
            let files = (try? context.fetch(FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.itemKey == showKey }))) ?? []
            let seasons = Set(files.compactMap(\.season))
            guard !seasons.isEmpty else { continue }
            var traktID = traktShowIDs[showKey]
            if traktID == nil, let trakt, let tmdbID = show.tmdbID { traktID = try? await trakt.showID(tmdb: tmdbID) }
            for number in seasons.sorted() {
                status = "Tải thông tin \(show.title) mùa \(number)…"
                var episodes: [Int: (title: String?, overview: String?, still: String?, airDate: String?)] = [:]
                if let tmdb, let id = show.tmdbID {
                    guard let season = try? await tmdb.season(show: id, number: number) else { continue }
                    for info in season.episodes { episodes[info.episodeNumber] = (info.name, info.overview, info.stillPath, info.airDate) }
                } else if let trakt, let traktID {
                    guard let season = try? await trakt.season(show: traktID, number: number) else { continue }
                    for info in season { episodes[info.number] = (info.title, info.overview, info.stillPath, info.airDate) }
                }
                for file in files where file.season == number {
                    guard let episode = file.episode, let info = episodes[episode] else { continue }
                    file.episodeTitle = info.title
                    file.episodeOverview = info.overview
                    file.stillPath = info.still
                    file.airDate = info.airDate
                }
            }
        }
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

    private static let coverNames = ["cover", "folder", "front", "album", "albumart", "albumartsmall"]

    /// Video files (with their subtitles), or audio tracks (with a cover image of their folder) for music folders.
    private static func collect(fs: RemoteFileSystem, root: String, audio: Bool = false, progress: @escaping (Int) -> Void) async throws -> [Found] {
        var results: [Found] = []
        var queue: [(path: String, depth: Int, name: String)] = [(root, 0, (root as NSString).lastPathComponent)]
        var showFolderName: [String: String] = [:]
        var parentName: [String: String] = [:]
        while !queue.isEmpty {
            let (path, depth, name) = queue.removeFirst()
            let items: [RemoteItem]
            do {
                items = try await fs.list(path)
            } catch {
                if depth == 0 { throw error }
                continue
            }
            if audio {
                let tracks = items.filter(\.isAudio)
                let images = items.filter { !$0.isDirectory && ["jpg", "jpeg", "png"].contains($0.fileExtension) && $0.size < 15_000_000 }
                let cover = coverNames.lazy.compactMap { name in images.first { $0.baseName.lowercased() == name } }.first ?? images.first
                for track in tracks {
                    results.append(Found(item: track, parentName: name, subtitles: [], directory: path,
                                         directoryParent: depth == 0 ? nil : parentName[path], cover: cover))
                }
            }
            let subtitles = items.filter(\.isSubtitle)
            let videos = audio ? [] : items.filter(\.isVideo)
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
                if depth > 0 || audio { parentName[dir.path] = depth == 0 ? nil : name }
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

    private func upsertItem(kind: LibraryKind, parsed: ParsedMediaName, tmdb: TMDbClient?, trakt: TraktMetadata?, context: ModelContext) async -> LibraryItem {
        let localKey = "local:\(kind.rawValue):\(parsed.title.lowercased())|\(kind == .movie ? parsed.year ?? 0 : 0)"
        var d = FetchDescriptor<LibraryItem>(predicate: #Predicate { $0.key == localKey })
        d.fetchLimit = 1
        if let existing = try? context.fetch(d).first {
            // A TMDb key added later replaces what Trakt filled in (TMDb has richer artwork and cast).
            if existing.tmdbID == nil || (tmdb != nil && TraktMetadata.isTraktImage(existing.posterPath)) {
                await enrich(existing, parsed: parsed, tmdb: tmdb, trakt: trakt)
            }
            return existing
        }
        let item = LibraryItem(key: localKey, kind: kind, title: parsed.title, year: parsed.year)
        context.insert(item)
        await enrich(item, parsed: parsed, tmdb: tmdb, trakt: trakt)
        return item
    }

    private func enrich(_ item: LibraryItem, parsed: ParsedMediaName, tmdb: TMDbClient?, trakt: TraktMetadata?) async {
        if let tmdb {
            await enrich(item, parsed: parsed, tmdb: tmdb)
        } else if let trakt {
            await enrich(item, parsed: parsed, trakt: trakt)
        }
    }

    private func enrich(_ item: LibraryItem, parsed: ParsedMediaName, trakt: TraktMetadata) async {
        do {
            let found = item.kind == .movie
                ? try await trakt.movie(title: parsed.title, year: parsed.year)
                : try await trakt.show(title: parsed.title, year: nil)
            guard let details = found else { return }
            if item.kind == .show { traktShowIDs[item.key] = details.traktID }
            item.tmdbID = details.tmdbID
            item.title = details.title.isEmpty ? item.title : details.title
            item.originalTitle = details.originalTitle
            item.year = details.year ?? item.year
            item.overview = details.overview
            item.tagline = details.tagline
            item.posterPath = details.posterPath
            item.backdropPath = details.backdropPath
            item.rating = details.rating
            item.runtime = details.runtime
            item.genres = details.genres
            item.cast = details.cast
            item.updatedAt = .now
        } catch {
            lastError = "Trakt: \(error.localizedDescription)"
        }
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
