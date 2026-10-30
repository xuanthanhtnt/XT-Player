import SwiftData
import SwiftUI

/// What a library grid shows (sidebar entries on the Mac, "Xem tất cả" from the home shelves).
enum LibraryFilter: String, Hashable, CaseIterable {
    case movies, shows, recent, unwatched, topRated

    var title: String {
        switch self {
        case .movies: return "Phim"
        case .shows: return "TV Shows"
        case .recent: return "Mới thêm"
        case .unwatched: return "Chưa xem"
        case .topRated: return "Điểm cao"
        }
    }

    var emptyText: String {
        switch self {
        case .unwatched: return "Bạn đã xem hết mọi thứ trong thư viện."
        case .topRated: return "Chưa có mục nào có điểm TMDb."
        default: return "Thư viện trống — thêm thư mục từ mục Nguồn."
        }
    }
}

struct LibraryGridView: View {
    let filter: LibraryFilter

    @Query(sort: \LibraryItem.title) private var allItems: [LibraryItem]
    @Query private var files: [LibraryFile]
    @Query private var entries: [MediaEntry]
    @State private var sort: Sort

    init(kind: LibraryKind) {
        self.init(filter: kind == .movie ? .movies : .shows)
    }

    init(filter: LibraryFilter) {
        self.filter = filter
        _sort = State(initialValue: filter == .topRated ? .rating : .recent)
    }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Mới thêm"
        case title = "Tên"
        case year = "Năm"
        case rating = "Điểm"
        var id: String { rawValue }
    }

    var body: some View {
        let index = LibraryIndex(files: files, entries: entries)
        let shown = items(index)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if filter != .recent {
                    Picker("Sắp xếp", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                }

                if shown.isEmpty {
                    Text(filter.emptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth * 1.25), spacing: Self.spacing)],
                          alignment: .leading, spacing: Self.spacing) {
                    ForEach(shown) { item in
                        PosterLink(item: item, index: index)
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .pageTitle(filter.title)
        .background(AppBackground())
    }

    private func items(_ index: LibraryIndex) -> [LibraryItem] {
        var list: [LibraryItem]
        switch filter {
        case .movies: list = allItems.filter { $0.kind == .movie }
        case .shows: list = allItems.filter { $0.kind == .show }
        case .recent: return Array(allItems.filter { $0.kind == .movie || $0.kind == .show }.sorted { $0.addedAt > $1.addedAt }.prefix(60))
        case .unwatched: list = allItems.filter { $0.kind != .album && index.isUnplayed($0) }
        case .topRated: list = allItems.filter { ($0.rating ?? 0) > 0 }
        }
        switch sort {
        case .recent: return list.sorted { $0.addedAt > $1.addedAt }
        case .title: return list
        case .year: return list.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: return list.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
    }

    #if os(tvOS)
    static let spacing: CGFloat = 48
    #else
    static let spacing: CGFloat = 18
    #endif
}

/// One shelf per genre (Infuse's "Movie Genres").
struct GenresView: View {
    @Query(sort: \LibraryItem.title) private var items: [LibraryItem]
    @Query private var files: [LibraryFile]
    @Query private var entries: [MediaEntry]

    var body: some View {
        let index = LibraryIndex(files: files, entries: entries)
        let byGenre = Dictionary(grouping: items.flatMap { item in item.genres.map { ($0, item) } }, by: { $0.0 })
        let genres = byGenre.keys.sorted { (byGenre[$0]?.count ?? 0, $1) > (byGenre[$1]?.count ?? 0, $0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if genres.isEmpty {
                    Text("Chưa có thể loại — thêm khoá TMDb trong Cài đặt rồi quét lại thư viện.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.pagePadding)
                }
                ForEach(genres, id: \.self) { genre in
                    ShelfRow(title: genre) {
                        ForEach(byGenre[genre]?.map { $0.1 } ?? []) { PosterLink(item: $0, index: index) }
                    }
                }
            }
            .padding(.vertical, Theme.pagePadding / 2)
        }
        .pageTitle("Thể loại")
        .background(AppBackground())
    }
}

/// Searches titles, original titles, genres and cast of the library.
struct LibrarySearchView: View {
    @Query(sort: \LibraryItem.title) private var items: [LibraryItem]
    @Query private var files: [LibraryFile]
    @Query private var entries: [MediaEntry]
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let index = LibraryIndex(files: files, entries: entries)
        let results = matches
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Tên phim, TV show, thể loại, diễn viên…", text: $query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        #if !os(tvOS)
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .font(.title3)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassPanel(cornerRadius: 12)
                .frame(maxWidth: 620)

                if !query.isEmpty, results.isEmpty {
                    Text("Không tìm thấy \"\(query)\" trong thư viện.").font(.callout).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth * 1.25), spacing: LibraryGridView.spacing)],
                          alignment: .leading, spacing: LibraryGridView.spacing) {
                    ForEach(results) { PosterLink(item: $0, index: index) }
                }
            }
            .padding(Theme.pagePadding)
        }
        .pageTitle("Tìm kiếm")
        .background(AppBackground())
        .onAppear { focused = true }
    }

    private var matches: [LibraryItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return items.filter { item in
            item.title.localizedStandardContains(text)
                || (item.originalTitle?.localizedStandardContains(text) ?? false)
                || item.genres.contains { $0.localizedStandardContains(text) }
                || item.castMembers.contains { $0.name.localizedStandardContains(text) }
        }
    }
}

struct MediaDetailView: View {
    let itemKey: String

    @Environment(\.modelContext) private var context
    @Environment(\.play) private var play
    @EnvironmentObject private var scanner: LibraryScanner
    @Query private var matches: [LibraryItem]
    @Query private var itemFiles: [LibraryFile]
    @Query private var entries: [MediaEntry]
    @State private var season: Int?

    init(itemKey: String) {
        self.itemKey = itemKey
        _matches = Query(filter: #Predicate<LibraryItem> { $0.key == itemKey })
        _itemFiles = Query(filter: #Predicate<LibraryFile> { $0.itemKey == itemKey })
    }

    var body: some View {
        ScrollView {
            if let item = matches.first {
                VStack(alignment: .leading, spacing: 28) {
                    hero(item)
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: 900, alignment: .leading)
                            .padding(.horizontal, Theme.pagePadding)
                    }
                    if item.kind == .show {
                        episodes(item)
                    } else if files.count > 1 {
                        versions(item)
                    }
                    if !item.castMembers.isEmpty { cast(item) }
                }
                .padding(.bottom, Theme.pagePadding)
            } else {
                Text("Không tìm thấy mục này trong thư viện.").padding(Theme.pagePadding)
            }
        }
        .background { backdrop }
        .ignoresSafeArea(edges: .top)
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            if season == nil { season = defaultSeason }
        }
    }

    /// Infuse-style page: the backdrop, heavily blurred, tints the whole detail page.
    private var backdrop: some View {
        ZStack {
            AppBackground()
            if let item = matches.first, let path = item.backdropPath ?? item.posterPath {
                ArtworkImage(path: path, size: "w780")
                    .blur(radius: 70)
                    .opacity(0.5)
                    .overlay(Theme.background.opacity(0.35))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Data

    private var files: [LibraryFile] { itemFiles.sorted(by: LibraryOrdering.episodes) }

    private var entryByKey: [String: MediaEntry] {
        let keys = Set(itemFiles.map(\.key))
        return Dictionary(entries.filter { keys.contains($0.key) }.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var seasons: [Int] { Array(Set(files.compactMap(\.season))).sorted() }

    private var defaultSeason: Int? {
        if let next = nextUp, let s = next.season { return s }
        return seasons.first
    }

    /// The episode to continue with: the one in progress, else the first unwatched one.
    private var nextUp: LibraryFile? {
        let byKey = entryByKey
        if let inProgress = files.filter({ byKey[$0.key]?.resumePosition != nil })
            .max(by: { (byKey[$0.key]?.lastPlayedAt ?? .distantPast) < (byKey[$1.key]?.lastPlayedAt ?? .distantPast) }) {
            return inProgress
        }
        return files.first { !(byKey[$0.key]?.isWatched ?? false) } ?? files.first
    }

    // MARK: Sections

    /// Infuse's detail hero: a tall backdrop fading into the page, the title, a white Resume / Play
    /// button, a row of square action buttons with the facts beside them, then the progress line.
    private func hero(_ item: LibraryItem) -> some View {
        let target = item.kind == .show ? nextUp : files.first
        let entry = target.flatMap { entryByKey[$0.key] }
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(path: item.backdropPath ?? item.posterPath, size: "w1280", placeholderIcon: PosterCard.icon(item.kind))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mask(
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5),
                                               .init(color: .black.opacity(0.35), location: 0.8), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(
                        LinearGradient(colors: [Theme.background.opacity(0.55), .clear], startPoint: .bottomLeading, endPoint: .center)
                    )

                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title)
                        .font(.system(size: Self.titleSize, weight: .bold))
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.45), radius: 10)
                    if let target {
                        playButton(item, target: target, resume: entry?.resumePosition)
                    }
                    HStack(spacing: 7) {
                        actionButtons(item, target: target, resumable: entry?.resumePosition != nil)
                        Text(metaLine(item))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .padding(.leading, 12)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 18)
            }
            .containerRelativeFrame(.vertical) { length, _ in min(Self.heroMax, max(Self.heroMin, length * 0.7)) }

            if let entry, let resume = entry.resumePosition, entry.duration > 0 {
                ResumeLine(position: resume, duration: entry.duration)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 4)
            }
        }
    }

    private func playButton(_ item: LibraryItem, target: LibraryFile, resume: Double?) -> some View {
        let code = item.kind == .show ? target.episodeCode : nil
        return Button { start(item, at: target, fromBeginning: false) } label: {
            #if os(tvOS)
            Label(playLabel(item, target: target, resume: resume), systemImage: "play.fill").font(.headline)
            #else
            HStack(spacing: 6) {
                Text(resume == nil ? "Phát" : "Tiếp tục").fontWeight(.bold)
                if let code { Text(code).fontWeight(.semibold) }
                if let resume { Text(TimeFormat.fullClock(resume)).monospacedDigit() }
            }
            .font(.system(size: 15))
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .frame(minWidth: 218, minHeight: 38)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            #endif
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        #endif
    }

    @ViewBuilder
    private func actionButtons(_ item: LibraryItem, target: LibraryFile?, resumable: Bool) -> some View {
        let allWatched = !files.isEmpty && files.allSatisfy { entryByKey[$0.key]?.isWatched ?? false }
        squareButton(allWatched ? "eye.slash" : "eye", help: allWatched ? "Đánh dấu chưa xem" : "Đánh dấu đã xem") {
            for file in files {
                MediaLibrary.setWatched(!allWatched, key: file.key, title: item.title, in: context)
            }
        }
        if resumable, let target {
            squareButton("arrow.counterclockwise", help: "Xem từ đầu") { start(item, at: target, fromBeginning: true) }
        }
        // Music videos are never looked up on TMDb.
        if item.kind == .movie || item.kind == .show {
            squareButton("arrow.triangle.2.circlepath", help: "Làm mới thông tin TMDb") {
                Task { await scanner.refresh(item, context: context) }
            }
        }
    }

    private func squareButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: Self.squareIcon, weight: .semibold))
                #if !os(tvOS)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                #endif
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        .help(help)
        #endif
    }

    private func episodes(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(seasons, id: \.self) { number in
                            Button { season = number } label: {
                                Text(number == 0 ? "Đặc biệt" : "Mùa \(number)")
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    #if !os(tvOS)
                                    .background(Capsule().fill(season == number ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.white.opacity(0.1))))
                                    .foregroundStyle(season == number ? Color.black : Color.white)
                                    #endif
                            }
                            #if !os(tvOS)
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.vertical, 10)
                }
                .scrollClipDisabled()
            }
            let shown = files.filter { seasons.count <= 1 || $0.season == season }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(shown) { file in
                    Button { start(item, at: file, fromBeginning: false) } label: {
                        EpisodeRow(file: file, entry: entryByKey[file.key], fallbackImage: item.backdropPath)
                    }
                    .tileButtonStyle()
                    .contextMenu {
                        let watched = entryByKey[file.key]?.isWatched ?? false
                        Button {
                            MediaLibrary.setWatched(!watched, key: file.key, title: item.title, in: context)
                        } label: {
                            Label(watched ? "Đánh dấu chưa xem" : "Đánh dấu đã xem", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
        }
    }

    private func versions(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Phiên bản").font(.title3.weight(.bold))
            ForEach(files) { file in
                Button { start(item, at: file, fromBeginning: false) } label: {
                    HStack {
                        Image(systemName: "play.circle.fill").foregroundStyle(Theme.leaf)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.fileName).font(.callout).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file) + (file.badges.isEmpty ? "" : " · " + file.badges.joined(separator: " · ")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    #if !os(tvOS)
                    .glassPanel(cornerRadius: 12)
                    #endif
                }
                .tileButtonStyle()
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private func cast(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diễn viên").font(.title3.weight(.bold)).padding(.horizontal, Theme.pagePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(item.castMembers) { person in
                        VStack(spacing: 6) {
                            ArtworkImage(path: person.profilePath, size: "w185", placeholderIcon: "person.fill")
                                .frame(width: Self.castSize, height: Self.castSize)
                                .clipShape(Circle())
                            Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(person.character).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: Self.castSize + 20)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }
        }
    }

    // MARK: Helpers

    /// "2019   2 giờ 10 phút   ★ 7.8   4K HDR10" — Infuse's facts next to the action buttons.
    private func metaLine(_ item: LibraryItem) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if item.kind == .show {
            parts.append("\(max(1, seasons.count)) mùa · \(files.count) tập")
        } else if let runtime = item.runtime ?? files.first.flatMap({ entryByKey[$0.key] }).map({ Int(($0.duration / 60).rounded()) }),
                  runtime > 0 {
            parts.append(runtime >= 60 ? "\(runtime / 60) giờ \(runtime % 60) phút" : "\(runtime) phút")
        }
        if let rating = item.rating, rating > 0 { parts.append("★ " + String(format: "%.1f", rating)) }
        if let badges = files.first?.badges, !badges.isEmpty { parts.append(badges.prefix(3).joined(separator: " ")) }
        if !item.genres.isEmpty, item.kind == .movie { parts.append(item.genres.prefix(2).joined(separator: ", ")) }
        return parts.joined(separator: "    ")
    }

    private func playLabel(_ item: LibraryItem, target: LibraryFile, resume: Double?) -> String {
        let code = item.kind == .show ? (target.episodeCode.map { " \($0)" } ?? "") : ""
        if let resume { return "Tiếp tục\(code) · \(TimeFormat.clock(resume))" }
        return "Phát\(code)"
    }

    private func start(_ item: LibraryItem, at file: LibraryFile, fromBeginning: Bool) {
        let queueFiles = item.kind == .show ? files : [file]
        var queue = PlaybackFactory.library(queueFiles, item: item, context: context)
        guard let index = queue.firstIndex(where: { $0.key == file.key }) else { return }
        if fromBeginning { queue[index].startAt = nil }
        play(PlaybackSession(items: queue, startIndex: index))
    }

    #if os(tvOS)
    private static let heroMin: CGFloat = 640
    private static let heroMax: CGFloat = 860
    private static let titleSize: CGFloat = 58
    private static let squareIcon: CGFloat = 24
    private static let castSize: CGFloat = 130
    #else
    private static let heroMin: CGFloat = 400
    private static let heroMax: CGFloat = 820
    private static let titleSize: CGFloat = 34
    private static let squareIcon: CGFloat = 15
    private static let castSize: CGFloat = 76
    #endif
}

/// Thin progress line under the hero with the resume point and the length (Infuse's detail page).
private struct ResumeLine: View {
    let position: Double
    let duration: Double

    var body: some View {
        let fraction = min(1, max(0, position / duration))
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(Theme.leaf).frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
            GeometryReader { geo in
                let x = geo.size.width * fraction
                ZStack(alignment: .topLeading) {
                    Text(TimeFormat.clock(position))
                        .fixedSize()
                        .position(x: min(max(x, 24), max(24, geo.size.width - 90)), y: 7)
                    Text(TimeFormat.clock(duration))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 15)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct EpisodeRow: View {
    let file: LibraryFile
    let entry: MediaEntry?
    let fallbackImage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkImage(path: file.stillPath ?? fallbackImage, size: "w300", placeholderIcon: "tv")
                .frame(width: Self.stillWidth, height: Self.stillWidth * 9 / 16)
                .overlay(alignment: .bottom) {
                    if let progress = entry?.resumePosition != nil ? entry?.progress : nil {
                        ProgressLine(value: progress).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if entry?.isWatched == true {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Theme.leaf).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text([file.episodeCode, file.episodeTitle].compactMap { $0 }.joined(separator: " · ").ifEmpty(file.fileName))
                    .font(.headline)
                    .lineLimit(1)
                if let overview = file.episodeOverview, !overview.isEmpty {
                    Text(overview).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                if !file.badges.isEmpty {
                    Text(file.badges.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if !os(tvOS)
        .glassPanel(cornerRadius: 14)
        .contentShape(Rectangle())
        #endif
    }

    #if os(tvOS)
    private static let stillWidth: CGFloat = 300
    #else
    private static let stillWidth: CGFloat = 160
    #endif
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
