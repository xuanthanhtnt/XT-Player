import SwiftData
import SwiftUI

/// Infuse-style home: a rotating featured hero, then Continue Watching / Recently Added / Movies / TV shelves.
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.play) private var play
    @Environment(\.openSection) private var openSection
    @EnvironmentObject private var scanner: LibraryScanner
    @Query(sort: \LibraryItem.addedAt, order: .reverse) private var items: [LibraryItem]
    @Query(sort: \MediaEntry.lastPlayedAt, order: .reverse) private var entries: [MediaEntry]
    @Query private var files: [LibraryFile]
    @State private var featuredIndex = 0
    @State private var errorMessage: String?

    var body: some View {
        let index = LibraryIndex(files: files, entries: entries)
        let featured = featuredItems(index)
        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if featured.isEmpty {
                    WelcomeHero(onAddSource: { openSection(.sources) })
                } else {
                    FeaturedHero(item: featured[featuredIndex % featured.count], index: index,
                                 pageCount: featured.count, page: featuredIndex % featured.count,
                                 onPlay: { start($0, index: index) })
                        .id(featured[featuredIndex % featured.count].key)
                        .transition(.opacity)
                }
                if scanner.isScanning || scanner.lastError != nil { scanBanner }
                if !continueWatching.isEmpty { continueRow }
                if !filmsAndShows.isEmpty {
                    ShelfRow(title: "Mới thêm") {
                        ForEach(filmsAndShows.prefix(20)) { posterLink($0, index: index) }
                    }
                }
                if !movies.isEmpty {
                    ShelfRow(title: "Phim", seeAll: .grid(kind: LibraryKind.movie.rawValue)) {
                        ForEach(movies.prefix(24)) { posterLink($0, index: index) }
                    }
                }
                if !shows.isEmpty {
                    ShelfRow(title: "TV Shows", seeAll: .grid(kind: LibraryKind.show.rawValue)) {
                        ForEach(shows.prefix(24)) { posterLink($0, index: index) }
                    }
                }
                if !musicVideos.isEmpty {
                    ShelfRow(title: "Video ca nhạc", seeAll: .grid(kind: LibraryKind.musicVideo.rawValue)) {
                        ForEach(musicVideos.prefix(20)) { MusicVideoLink(item: $0, index: index) }
                    }
                }
                if !albums.isEmpty {
                    ShelfRow(title: "Nhạc", seeAll: .grid(kind: LibraryKind.album.rawValue)) {
                        ForEach(albums.prefix(20)) { AlbumLink(item: $0, index: index) }
                    }
                }
            }
            .padding(.bottom, Theme.pagePadding)
        }
        .background(AppBackground())
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .animation(.easeInOut(duration: 0.6), value: featuredIndex)
        .task(id: featured.count) {
            // Rotate the hero every 9 s, like the featured banner of streaming apps.
            guard featured.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                if Task.isCancelled { break }
                featuredIndex += 1
            }
        }
        .alert("Không mở được", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Data

    private var movies: [LibraryItem] { items.filter { $0.kind == .movie } }
    private var shows: [LibraryItem] { items.filter { $0.kind == .show } }
    private var filmsAndShows: [LibraryItem] { items.filter { $0.kind == .movie || $0.kind == .show } }
    private var musicVideos: [LibraryItem] { items.filter { $0.kind == .musicVideo } }
    private var albums: [LibraryItem] { items.filter { $0.kind == .album } }
    /// Films and episodes left half-watched (music is resumed from its album, not from here).
    private var continueWatching: [MediaEntry] {
        Array(entries.filter {
            $0.resumePosition != nil && !FilenameParser.audioExtensions.contains(($0.urlString as NSString).pathExtension.lowercased())
        }.prefix(16))
    }

    /// In-progress titles first, then the newest additions with artwork.
    private func featuredItems(_ index: LibraryIndex) -> [LibraryItem] {
        var picked: [LibraryItem] = []
        var seen = Set<String>()
        for entry in continueWatching {
            if let item = index.item(forFileKey: entry.key, in: items), seen.insert(item.key).inserted { picked.append(item) }
        }
        for item in items where item.kind != .album && item.backdropPath != nil && seen.insert(item.key).inserted {
            picked.append(item)
        }
        picked.removeAll { $0.kind == .album }
        if picked.isEmpty, let first = items.first(where: { $0.kind != .album }) { picked = [first] }
        return Array(picked.prefix(6))
    }

    // MARK: Sections

    private var scanBanner: some View {
        HStack(spacing: 12) {
            if scanner.isScanning { ProgressView() }
            Text(scanner.lastError ?? scanner.status)
                .font(.callout)
                .foregroundStyle(scanner.lastError == nil ? Color.secondary : Theme.danger)
                .lineLimit(2)
            Spacer()
        }
        .padding(16)
        .glassPanel()
        .padding(.horizontal, Theme.pagePadding)
    }

    private var continueRow: some View {
        ShelfRow(title: "Tiếp tục xem") {
            ForEach(continueWatching) { entry in
                Button { resume(entry) } label: {
                    LandscapeCard(title: entry.title, subtitle: entry.subtitle ?? remaining(entry),
                                  imagePath: entry.artworkPath, progress: entry.progress,
                                  icon: entry.isLocalFile ? "film" : "network")
                }
                .tileButtonStyle()
                .contextMenu {
                    Button { MediaLibrary.setWatched(true, key: entry.key, title: entry.title, in: context) } label: {
                        Label("Đánh dấu đã xem", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        context.delete(entry)
                        try? context.save()
                    } label: { Label("Xoá khỏi danh sách", systemImage: "trash") }
                }
            }
        }
    }

    private func posterLink(_ item: LibraryItem, index: LibraryIndex) -> some View {
        let state = index.progress(of: item)
        return NavigationLink(value: item.kind == .album ? Route.album(itemKey: item.key) : Route.detail(itemKey: item.key)) {
            PosterCard(item: item, progress: state.progress, watched: state.watched)
        }
        .tileButtonStyle()
    }

    // MARK: Actions

    private func start(_ item: LibraryItem, index: LibraryIndex) {
        let itemFiles = index.files(of: item).sorted(by: LibraryOrdering.episodes)
        guard !itemFiles.isEmpty else { return }
        let queue = PlaybackFactory.library(item.kind == .show ? itemFiles : [itemFiles[0]], item: item, context: context)
        let target = index.nextUp(in: itemFiles)
        let start = queue.firstIndex { $0.key == target?.key } ?? 0
        guard !queue.isEmpty else { return }
        play(PlaybackSession(items: queue, startIndex: start))
    }

    private func resume(_ entry: MediaEntry) {
        // An episode resumes with the rest of its season queued behind it.
        if let file = PlaybackFactory.libraryFile(key: entry.key, context: context),
           let item = items.first(where: { $0.key == file.itemKey }) {
            let siblings = files.filter { $0.itemKey == item.key }.sorted(by: LibraryOrdering.episodes)
            let queue = PlaybackFactory.library(siblings, item: item, context: context)
            if let start = queue.firstIndex(where: { $0.key == entry.key }) {
                play(PlaybackSession(items: queue, startIndex: start))
                return
            }
        }
        guard let item = PlaybackFactory.resume(entry, context: context) else {
            errorMessage = "Không tìm thấy tệp hoặc máy chủ. Hãy mở lại từ Nguồn."
            return
        }
        play(PlaybackSession(item: item))
    }

    private func remaining(_ entry: MediaEntry) -> String? {
        guard entry.duration > 0 else { return nil }
        return "Còn \(TimeFormat.clock(max(0, entry.duration - entry.position)))"
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.1"
}

// MARK: - Hero

/// Full-bleed backdrop with title, facts, synopsis and Play — the top of Infuse's home screen.
struct FeaturedHero: View {
    let item: LibraryItem
    let index: LibraryIndex
    var pageCount = 1
    var page = 0
    let onPlay: (LibraryItem) -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(path: item.backdropPath ?? item.posterPath, size: "w1280")
                .frame(height: Self.height)
                .frame(maxWidth: .infinity)
                .overlay(
                    LinearGradient(colors: [.clear, Theme.background.opacity(0.35), Theme.background],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    LinearGradient(colors: [Theme.background.opacity(0.85), .clear], startPoint: .leading, endPoint: .center)
                )

            VStack(alignment: .leading, spacing: 12) {
                Text(item.kind == .show ? "TV SHOW" : item.kind == .musicVideo ? "VIDEO CA NHẠC" : "PHIM")
                    .font(.caption.weight(.heavy))
                    .tracking(2)
                    .foregroundStyle(Theme.leaf)
                Text(item.title)
                    .font(.system(size: Self.titleSize, weight: .heavy))
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 8)
                HStack(spacing: 8) {
                    Text(facts).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                    ForEach(index.badges(of: item).prefix(4), id: \.self) {
                        TagChip(text: $0, highlighted: $0 == "DV" || $0.hasPrefix("HDR"))
                    }
                }
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(3)
                        .frame(maxWidth: 640, alignment: .leading)
                }
                HStack(spacing: 14) {
                    Button { onPlay(item) } label: {
                        Label(playTitle, systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 8)
                    }
                    #if !os(tvOS)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .controlSize(.large)
                    #endif
                    NavigationLink(value: Route.detail(itemKey: item.key)) {
                        Label("Chi tiết", systemImage: "info.circle")
                            .font(.headline)
                    }
                    #if !os(tvOS)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    #endif
                    Spacer()
                    if pageCount > 1 {
                        HStack(spacing: 6) {
                            ForEach(0..<pageCount, id: \.self) { i in
                                Capsule().fill(i == page ? Color.white : Color.white.opacity(0.3))
                                    .frame(width: i == page ? 18 : 6, height: 6)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 12)
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if item.kind == .movie, let runtime = item.runtime, runtime > 0 { parts.append("\(runtime / 60)h \(runtime % 60)m") }
        if let rating = item.rating, rating > 0 { parts.append("★ " + String(format: "%.1f", rating)) }
        if let genre = item.genres.first { parts.append(genre) }
        return parts.joined(separator: " · ")
    }

    private var playTitle: String {
        guard let next = index.nextUp(in: index.files(of: item).sorted(by: LibraryOrdering.episodes)) else { return "Phát" }
        if index.entry(for: next)?.resumePosition != nil { return item.kind == .show ? "Tiếp tục \(next.episodeCode ?? "")" : "Tiếp tục" }
        return item.kind == .show ? "Phát \(next.episodeCode ?? "")" : "Phát"
    }

    #if os(tvOS)
    static let height: CGFloat = 860
    static let titleSize: CGFloat = 72
    #elseif os(macOS)
    static let height: CGFloat = 520
    static let titleSize: CGFloat = 46
    #else
    static let height: CGFloat = 480
    static let titleSize: CGFloat = 36
    #endif
}

/// Shown until the library has something in it.
struct WelcomeHero: View {
    let onAddSource: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: Self.markSize, height: Self.markSize)
                .shadow(color: Theme.forest.opacity(0.5), radius: 30, y: 12)
            Text("XT-Player")
                .font(.system(size: Self.titleSize, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.brandGradient)
            Text("Thêm NAS / máy chủ SMB hoặc WebDAV, chọn thư mục phim và \"Thêm vào thư viện\".\nPoster, nội dung và diễn viên được lấy tự động từ TMDb.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 620)
            HStack(spacing: 14) {
                Button(action: onAddSource) {
                    Label("Thêm nguồn", systemImage: "plus.circle.fill").font(.headline)
                }
                #if !os(tvOS)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                #endif
                #if !os(tvOS)
                Button {
                    NotificationCenter.default.post(name: .xtOpenFileRequested, object: nil)
                } label: {
                    Label("Mở tệp", systemImage: "folder").font(.headline)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                #endif
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Self.topPadding)
        .padding(.bottom, 20)
        .padding(.horizontal, Theme.pagePadding)
    }

    #if os(tvOS)
    static let markSize: CGFloat = 260
    static let titleSize: CGFloat = 76
    static let topPadding: CGFloat = 140
    #else
    static let markSize: CGFloat = 150
    static let titleSize: CGFloat = 44
    static let topPadding: CGFloat = 90
    #endif
}

// MARK: - Helpers

enum LibraryOrdering {
    static func episodes(_ a: LibraryFile, _ b: LibraryFile) -> Bool {
        let sa = a.season ?? Int.max, sb = b.season ?? Int.max
        if sa != sb { return sa < sb }
        let ea = a.episode ?? Int.max, eb = b.episode ?? Int.max
        if ea != eb { return ea < eb }
        return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
    }
}

/// Per-render lookup tables so shelves don't scan every file for every poster.
struct LibraryIndex {
    private let filesByItem: [String: [LibraryFile]]
    private let filesByKey: [String: LibraryFile]
    private let entriesByKey: [String: MediaEntry]

    init(files: [LibraryFile], entries: [MediaEntry]) {
        filesByItem = Dictionary(grouping: files, by: \.itemKey)
        filesByKey = Dictionary(files.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        entriesByKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func files(of item: LibraryItem) -> [LibraryFile] { filesByItem[item.key] ?? [] }
    func entry(for file: LibraryFile) -> MediaEntry? { entriesByKey[file.key] }

    func item(forFileKey key: String, in items: [LibraryItem]) -> LibraryItem? {
        guard let file = filesByKey[key] else { return nil }
        return items.first { $0.key == file.itemKey }
    }

    func badges(of item: LibraryItem) -> [String] { files(of: item).first?.badges ?? [] }

    /// The file to continue with: the one in progress, else the first unwatched one.
    func nextUp(in sorted: [LibraryFile]) -> LibraryFile? {
        if let inProgress = sorted.filter({ entriesByKey[$0.key]?.resumePosition != nil })
            .max(by: { (entriesByKey[$0.key]?.lastPlayedAt ?? .distantPast) < (entriesByKey[$1.key]?.lastPlayedAt ?? .distantPast) }) {
            return inProgress
        }
        return sorted.first { !(entriesByKey[$0.key]?.isWatched ?? false) } ?? sorted.first
    }

    /// "Unwatched": a film never played (in progress counts as played, as in Infuse); a show with an episode
    /// not played yet.
    func isUnplayed(_ item: LibraryItem) -> Bool {
        let files = filesByItem[item.key] ?? []
        let unplayed: (LibraryFile) -> Bool = { !(entriesByKey[$0.key]?.isStarted ?? false) }
        return item.kind == .show ? files.contains(where: unplayed) : files.allSatisfy(unplayed)
    }

    func progress(of item: LibraryItem) -> (progress: Double?, watched: Bool) {
        let files = filesByItem[item.key] ?? []
        let mine = files.compactMap { entriesByKey[$0.key] }
        if item.kind == .movie || item.kind == .musicVideo {
            let best = mine.max { ($0.progress ?? 0) < ($1.progress ?? 0) }
            return (best?.resumePosition != nil ? best?.progress : nil, best?.isWatched ?? false)
        }
        let watched = mine.filter(\.isWatched).count
        return (nil, !files.isEmpty && watched == files.count)
    }
}

struct SourceCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if !os(tvOS)
        .glassPanel()
        .contentShape(Rectangle())
        #endif
    }
}
