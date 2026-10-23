import SwiftData
import SwiftUI

struct LibraryGridView: View {
    let kind: LibraryKind

    @Query(sort: \LibraryItem.title) private var allItems: [LibraryItem]
    @State private var sort: Sort = .recent

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Mới thêm"
        case title = "Tên"
        case year = "Năm"
        case rating = "Điểm"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Sắp xếp", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth * 1.25), spacing: Self.spacing)],
                          alignment: .leading, spacing: Self.spacing) {
                    ForEach(items) { item in
                        NavigationLink(value: Route.detail(itemKey: item.key)) {
                            PosterCard(item: item)
                        }
                        .tileButtonStyle()
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .background(AppBackground())
        .navigationTitle(kind == .movie ? "Phim" : "TV Shows")
    }

    private var items: [LibraryItem] {
        let filtered = allItems.filter { $0.kind == kind }
        switch sort {
        case .recent: return filtered.sorted { $0.addedAt > $1.addedAt }
        case .title: return filtered
        case .year: return filtered.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: return filtered.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
    }

    #if os(tvOS)
    private static let spacing: CGFloat = 48
    #else
    private static let spacing: CGFloat = 18
    #endif
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

    private func hero(_ item: LibraryItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(path: item.backdropPath ?? item.posterPath, size: "w1280")
                .frame(height: Self.heroHeight)
                .frame(maxWidth: .infinity)
                .mask(
                    LinearGradient(colors: [.black, .black, .black.opacity(0.4), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
            HStack(alignment: .bottom, spacing: 24) {
                ArtworkImage(path: item.posterPath, size: "w342", placeholderIcon: item.kind == .show ? "tv" : "film")
                    .frame(width: Self.posterWidth, height: Self.posterWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title)
                        .font(.system(size: Self.titleSize, weight: .heavy))
                        .lineLimit(2)
                    Text(metaLine(item))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                    if !item.genres.isEmpty {
                        Text(item.genres.prefix(4).joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if let badges = files.first?.badges, !badges.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(badges, id: \.self) { TagChip(text: $0, highlighted: $0 == "DV" || $0.hasPrefix("HDR")) }
                        }
                    }
                    actions(item)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 8)
        }
    }

    private func actions(_ item: LibraryItem) -> some View {
        HStack(spacing: 14) {
            if let target = item.kind == .show ? nextUp : files.first {
                let resume = entryByKey[target.key]?.resumePosition
                Button { start(item, at: target, fromBeginning: false) } label: {
                    Label(playLabel(item, target: target, resume: resume), systemImage: "play.fill")
                        .font(.headline)
                }
                #if !os(tvOS)
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .controlSize(.large)
                #endif
                if resume != nil {
                    Button { start(item, at: target, fromBeginning: true) } label: {
                        Label("Từ đầu", systemImage: "backward.end.fill").font(.headline)
                    }
                    #if !os(tvOS)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    #endif
                }
            }
            Menu {
                let allWatched = !files.isEmpty && files.allSatisfy { entryByKey[$0.key]?.isWatched ?? false }
                Button {
                    for file in files {
                        MediaLibrary.setWatched(!allWatched, key: file.key, title: item.title, in: context)
                    }
                } label: {
                    Label(allWatched ? "Đánh dấu chưa xem" : "Đánh dấu đã xem", systemImage: allWatched ? "circle" : "checkmark.circle")
                }
                Button {
                    Task { await scanner.refresh(item, context: context) }
                } label: {
                    Label("Làm mới thông tin TMDb", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
            #if !os(tvOS)
            .buttonStyle(.plain)
            #endif
        }
        .padding(.top, 6)
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

    private func metaLine(_ item: LibraryItem) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if item.kind == .show {
            let count = files.count
            parts.append("\(seasons.count) mùa · \(count) tập")
        } else if let runtime = item.runtime, runtime > 0 {
            parts.append("\(runtime / 60)h \(runtime % 60)m")
        }
        if let rating = item.rating, rating > 0 { parts.append("★ " + String(format: "%.1f", rating)) }
        return parts.joined(separator: " · ")
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
    private static let heroHeight: CGFloat = 700
    private static let posterWidth: CGFloat = 260
    private static let titleSize: CGFloat = 58
    private static let castSize: CGFloat = 130
    #else
    private static let heroHeight: CGFloat = 480
    private static let posterWidth: CGFloat = 150
    private static let titleSize: CGFloat = 36
    private static let castSize: CGFloat = 76
    #endif
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
