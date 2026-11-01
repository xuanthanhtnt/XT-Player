import SwiftData
import SwiftUI

// Music in the library: albums (folders of tracks from "Nhạc" library folders) and music videos (files of
// "Video ca nhạc" folders), each with its own grid, kept apart from films and TV shows.

/// Square album cover with title and artist.
struct AlbumCard: View {
    let item: LibraryItem
    var played = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(path: item.posterPath, size: "w342", placeholderIcon: "music.note")
                .frame(width: Self.width, height: Self.width)
                .overlay(alignment: .topTrailing) {
                    if played {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, Theme.leaf).padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(item.artist ?? item.year.map(String.init) ?? "Album").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: Self.width, alignment: .leading)
        }
    }

    #if os(tvOS)
    static let width: CGFloat = 300
    #else
    static let width: CGFloat = 170
    #endif
}

struct AlbumLink: View {
    let item: LibraryItem
    let index: LibraryIndex
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationLink(value: Route.album(itemKey: item.key)) {
            AlbumCard(item: item, played: index.progress(of: item).watched)
        }
        .tileButtonStyle()
        .contextMenu {
            AlbumQueueActions(tracks: { index.files(of: item).sorted(by: LibraryOrdering.episodes) }, album: item, context: context)
        }
    }
}

/// Play / Play next / Add to queue for an album or a track (Roon's play menu).
struct AlbumQueueActions: View {
    let tracks: () -> [LibraryFile]
    let album: LibraryItem
    let context: ModelContext

    var body: some View {
        Button { MusicPlayer.shared.play(items(), context: context) } label: { Label("Phát", systemImage: "play.fill") }
        Button { MusicPlayer.shared.play(items(), shuffle: true, context: context) } label: { Label("Trộn bài", systemImage: "shuffle") }
        Button { MusicPlayer.shared.playNext(items(), context: context) } label: { Label("Phát tiếp", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { MusicPlayer.shared.addToQueue(items(), context: context) } label: { Label("Thêm vào hàng đợi", systemImage: "text.line.last.and.arrowtriangle.forward") }
    }

    private func items() -> [PlaybackItem] { PlaybackFactory.library(tracks(), item: album, context: context) }
}

/// 16:9 frame of a music video with its artist / show.
struct MusicVideoLink: View {
    let item: LibraryItem
    let index: LibraryIndex

    var body: some View {
        let state = index.progress(of: item)
        NavigationLink(value: Route.detail(itemKey: item.key)) {
            LandscapeCard(title: item.title, subtitle: item.artist ?? item.year.map(String.init),
                          imagePath: item.backdropPath, progress: state.progress, icon: "music.note.tv")
                .overlay(alignment: .topTrailing) {
                    if state.watched {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, Theme.leaf).padding(8)
                    }
                }
        }
        .tileButtonStyle()
    }
}

/// All albums, newest first or by artist / title.
struct AlbumsView: View {
    @Query(sort: \LibraryItem.addedAt, order: .reverse) private var allItems: [LibraryItem]
    @Query private var files: [LibraryFile]
    @Query private var entries: [MediaEntry]
    @State private var sort = Sort.recent
    var embedded = false

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Mới thêm"
        case artist = "Nghệ sĩ"
        case title = "Tên"
        var id: String { rawValue }
    }

    var body: some View {
        let index = LibraryIndex(files: files, entries: entries)
        let albums = sorted(allItems.filter { $0.kind == .album })
        let grid = VStack(alignment: .leading, spacing: 20) {
            if albums.isEmpty {
                MusicEmptyHint(kind: .music)
            } else {
                Picker("Sắp xếp", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: AlbumCard.width, maximum: AlbumCard.width * 1.2), spacing: Self.spacing)],
                          alignment: .leading, spacing: Self.spacing) {
                    ForEach(albums) { AlbumLink(item: $0, index: index) }
                }
            }
        }
        .padding(Theme.pagePadding)
        if embedded {
            grid
        } else {
            ScrollView { grid }.pageTitle("Nhạc").background(AppBackground())
        }
    }

    private func sorted(_ albums: [LibraryItem]) -> [LibraryItem] {
        switch sort {
        case .recent: return albums
        case .title: return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return albums.sorted { ($0.artist ?? "~", $0.year ?? 0, $0.title) < ($1.artist ?? "~", $1.year ?? 0, $1.title) }
        }
    }

    #if os(tvOS)
    static let spacing: CGFloat = 48
    #else
    static let spacing: CGFloat = 18
    #endif
}

/// All music videos, newest first or by artist.
struct MusicVideosView: View {
    @Query(sort: \LibraryItem.addedAt, order: .reverse) private var allItems: [LibraryItem]
    @Query private var files: [LibraryFile]
    @Query private var entries: [MediaEntry]
    @State private var byArtist = false
    var embedded = false

    var body: some View {
        let index = LibraryIndex(files: files, entries: entries)
        let videos = musicVideos
        let grid = VStack(alignment: .leading, spacing: 20) {
            if videos.isEmpty {
                MusicEmptyHint(kind: .musicVideos)
            } else {
                Picker("Sắp xếp", selection: $byArtist) {
                    Text("Mới thêm").tag(false)
                    Text("Nghệ sĩ / chương trình").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.landscapeWidth, maximum: Theme.landscapeWidth * 1.3), spacing: AlbumsView.spacing)],
                          alignment: .leading, spacing: AlbumsView.spacing) {
                    ForEach(videos) { MusicVideoLink(item: $0, index: index) }
                }
            }
        }
        .padding(Theme.pagePadding)
        if embedded {
            grid
        } else {
            ScrollView { grid }.pageTitle("Video ca nhạc").background(AppBackground())
        }
    }

    private var musicVideos: [LibraryItem] {
        let videos = allItems.filter { $0.kind == .musicVideo }
        guard byArtist else { return videos }
        return videos.sorted { ($0.artist ?? "~", $0.title) < ($1.artist ?? "~", $1.title) }
    }
}

/// iPhone / iPad / Apple TV tab: albums and music videos side by side.
struct MusicLibraryView: View {
    enum Page: String, CaseIterable, Identifiable {
        case albums = "Album", artists = "Nghệ sĩ", videos = "Video ca nhạc"
        var id: String { rawValue }
    }

    @State private var page = Page.albums
    @ObservedObject private var music = MusicPlayer.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Picker("Nhạc", selection: $page) {
                        ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 480)
                    #if os(tvOS)
                    if music.isActive {
                        Button { music.showsNowPlaying = true } label: { Label("Đang phát", systemImage: "waveform") }
                    }
                    #endif
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 12)
                switch page {
                case .albums: AlbumsView(embedded: true)
                case .artists: ArtistsView(embedded: true)
                case .videos: MusicVideosView(embedded: true)
                }
            }
        }
        .pageTitle("Nhạc")
        .background(AppBackground())
    }
}

/// What to do when a music section is empty.
struct MusicEmptyHint: View {
    let kind: LibraryFolderKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(kind == .music ? "Chưa có album nào" : "Chưa có video ca nhạc nào", systemImage: kind.icon)
                .font(.headline)
            Text("Mở thư mục trên NAS ở mục Nguồn, bấm mũi tên cạnh “Thêm thư mục này vào thư viện” và chọn “\(kind.label)”. "
                 + "Thư mục đã thêm: giữ chuột phải (hoặc nhấn giữ) ở mục Nguồn ▸ Loại thư mục.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }
}

/// An album: cover, artist, track list; plays from any track to the end of the album.
struct AlbumDetailView: View {
    let itemKey: String

    @Environment(\.modelContext) private var context
    @ObservedObject private var music = MusicPlayer.shared
    @Query private var matches: [LibraryItem]
    @Query private var files: [LibraryFile]
    @Query private var entries: [MediaEntry]

    init(itemKey: String) {
        self.itemKey = itemKey
        _matches = Query(filter: #Predicate<LibraryItem> { $0.key == itemKey })
        _files = Query(filter: #Predicate<LibraryFile> { $0.itemKey == itemKey })
    }

    var body: some View {
        let tracks = files.sorted(by: LibraryOrdering.episodes)
        let entryByKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let discs = Set(tracks.compactMap(\.season))
        return ScrollView {
            if let album = matches.first {
                VStack(alignment: .leading, spacing: 24) {
                    header(album, tracks: tracks)
                    VStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.key) { position, track in
                            if discs.count > 1, track.season != tracks[max(0, position - 1)].season || position == 0 {
                                Text("Đĩa \(track.season ?? 1)")
                                    .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, position == 0 ? 0 : 16).padding(.bottom, 6)
                            }
                            Button { playAlbum(album, tracks: tracks, from: position) } label: {
                                TrackRow(number: track.episode ?? position + 1, title: track.episodeTitle ?? track.fileName,
                                         format: track.badges.first, duration: entryByKey[track.key]?.duration ?? 0,
                                         played: entryByKey[track.key]?.isWatched ?? false, playing: music.current?.key == track.key)
                            }
                            .tileButtonStyle()
                            .contextMenu {
                                AlbumQueueActions(tracks: { [track] }, album: album, context: context)
                            }
                            Divider().opacity(0.4)
                        }
                    }
                }
                .padding(Theme.pagePadding)
            }
        }
        // The header already shows the album title in large type.
        .navigationTitle(matches.first?.title ?? "Album")
        .background(AppBackground())
    }

    private func header(_ album: LibraryItem, tracks: [LibraryFile]) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            ArtworkImage(path: album.posterPath, size: "w500", placeholderIcon: "music.note")
                .frame(width: Self.cover, height: Self.cover)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(album.title).font(.title.weight(.bold)).lineLimit(2)
                if let artist = album.artist { Text(artist).font(.title3).foregroundStyle(Theme.leaf) }
                Text(summary(album, tracks: tracks)).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { playAlbum(album, tracks: tracks, from: 0) } label: { Label("Phát", systemImage: "play.fill") }
                    Button { music.play(PlaybackFactory.library(tracks, item: album, context: context), shuffle: true, context: context) } label: {
                        Label("Trộn bài", systemImage: "shuffle")
                    }
                    Menu {
                        Button { music.playNext(PlaybackFactory.library(tracks, item: album, context: context), context: context) } label: {
                            Label("Phát tiếp", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button { music.addToQueue(PlaybackFactory.library(tracks, item: album, context: context), context: context) } label: {
                            Label("Thêm vào hàng đợi", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    #if os(macOS)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    #endif
                }
                #if !os(tvOS)
                .buttonStyle(.borderedProminent)
                .tint(Theme.leaf)
                #endif
                .padding(.top, 6)
            }
        }
    }

    /// "2024 · 3 bài · 42 phút · FLAC · 96 kHz · 24-bit · 812 MB" (the quality once a track has been played).
    private func summary(_ album: LibraryItem, tracks: [LibraryFile]) -> String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(tracks.count) bài")
        let durations = entries.filter { entry in tracks.contains { $0.key == entry.key } }.map(\.duration).filter { $0 > 1 }
        if durations.count == tracks.count, !durations.isEmpty {
            let total = durations.reduce(0, +)
            parts.append(total >= 60 ? "\(Int((total / 60).rounded())) phút" : "\(Int(total)) giây")
        }
        let qualities = Array(Set(tracks.compactMap { $0.badges.count > 1 ? $0.badges[1] : nil })).sorted()
        let formats = Array(Set(tracks.compactMap { $0.badges.first })).sorted()
        if qualities.count == 1 { parts.append(qualities[0]) } else if !formats.isEmpty { parts.append(formats.joined(separator: " / ")) }
        let bytes = tracks.reduce(Int64(0)) { $0 + $1.size }
        parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func playAlbum(_ album: LibraryItem, tracks: [LibraryFile], from position: Int) {
        let queue = PlaybackFactory.library(tracks, item: album, context: context)
        music.play(queue, startAt: position, context: context)
    }

    #if os(tvOS)
    static let cover: CGFloat = 360
    #else
    static let cover: CGFloat = 200
    #endif
}

private struct TrackRow: View {
    let number: Int
    let title: String
    let format: String?
    let duration: Double
    let played: Bool
    let playing: Bool

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if playing {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.leaf)
                } else {
                    Text("\(number)").foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
            .frame(width: 30, alignment: .trailing)
            Text(title).font(.body.weight(playing ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(playing ? Theme.leaf : .primary)
            Spacer(minLength: 8)
            if played { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.leaf) }
            if let format { Text(format).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            if duration > 1 { Text(TimeFormat.clock(duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .trailing) }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Artists

/// Album artists, each with their albums (Roon's "Nghệ sĩ"): initials when there is no picture.
struct ArtistsView: View {
    @Query(sort: \LibraryItem.title) private var allItems: [LibraryItem]
    var embedded = false

    var body: some View {
        let artists = Dictionary(grouping: allItems.filter { $0.kind == .album }, by: { $0.artist ?? "Không rõ nghệ sĩ" })
        let names = artists.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let grid = VStack(alignment: .leading, spacing: 20) {
            if names.isEmpty {
                MusicEmptyHint(kind: .music)
            } else {
                Text("\(names.count) nghệ sĩ").font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: AlbumCard.width, maximum: AlbumCard.width * 1.2), spacing: AlbumsView.spacing)],
                          alignment: .leading, spacing: AlbumsView.spacing) {
                    ForEach(names, id: \.self) { name in
                        NavigationLink(value: Route.artist(name: name)) {
                            ArtistCard(name: name, albums: artists[name] ?? [])
                        }
                        .tileButtonStyle()
                    }
                }
            }
        }
        .padding(Theme.pagePadding)
        if embedded {
            grid
        } else {
            ScrollView { grid }.pageTitle("Nghệ sĩ").background(AppBackground())
        }
    }
}

private struct ArtistCard: View {
    let name: String
    let albums: [LibraryItem]

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.white.opacity(0.07))
                if let cover = albums.first(where: { ThumbnailStore.isUsable($0.posterPath) })?.posterPath {
                    ArtworkImage(path: cover, size: "w342", placeholderIcon: "music.mic").clipShape(Circle()).opacity(0.35)
                }
                Text(Self.initials(name)).font(.system(size: AlbumCard.width * 0.28, weight: .regular, design: .serif))
            }
            .frame(width: AlbumCard.width, height: AlbumCard.width)
            VStack(spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(albums.count) album").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: AlbumCard.width)
        }
    }

    /// "Ace of Base" → "AB", "Ánh Tuyết" → "ÁT".
    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.filter { !["of", "the", "và", "and", "&"].contains($0.lowercased()) }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "♪" : letters.joined()
    }
}

/// One artist's albums, newest first.
struct ArtistDetailView: View {
    let name: String
    @Query(sort: \LibraryItem.year, order: .reverse) private var allItems: [LibraryItem]
    @Query private var files: [LibraryFile]
    @Query private var entries: [MediaEntry]
    @Environment(\.modelContext) private var context

    var body: some View {
        let index = LibraryIndex(files: files, entries: entries)
        let albums = allItems.filter { $0.kind == .album && ($0.artist ?? "Không rõ nghệ sĩ") == name }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text("\(albums.count) album").font(.callout).foregroundStyle(.secondary)
                    Button {
                        let tracks = albums.flatMap { album in
                            PlaybackFactory.library(index.files(of: album).sorted(by: LibraryOrdering.episodes), item: album, context: context)
                        }
                        MusicPlayer.shared.play(tracks, shuffle: true, context: context)
                    } label: { Label("Trộn tất cả", systemImage: "shuffle") }
                    #if !os(tvOS)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.leaf)
                    #endif
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: AlbumCard.width, maximum: AlbumCard.width * 1.2), spacing: AlbumsView.spacing)],
                          alignment: .leading, spacing: AlbumsView.spacing) {
                    ForEach(albums) { AlbumLink(item: $0, index: index) }
                }
            }
            .padding(Theme.pagePadding)
        }
        .pageTitle(name)
        .background(AppBackground())
    }
}
