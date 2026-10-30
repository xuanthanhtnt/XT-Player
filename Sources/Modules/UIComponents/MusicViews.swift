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

    var body: some View {
        NavigationLink(value: Route.album(itemKey: item.key)) {
            AlbumCard(item: item, played: index.progress(of: item).watched)
        }
        .tileButtonStyle()
    }
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
    @State private var showVideos = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Nhạc", selection: $showVideos) {
                    Text("Album").tag(false)
                    Text("Video ca nhạc").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 12)
                if showVideos {
                    MusicVideosView(embedded: true)
                } else {
                    AlbumsView(embedded: true)
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
    @Environment(\.play) private var play
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
                                         format: track.badges.first, played: entryByKey[track.key]?.isWatched ?? false)
                            }
                            .tileButtonStyle()
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
                    Button { playAlbum(album, tracks: tracks.shuffled(), from: 0) } label: { Label("Trộn bài", systemImage: "shuffle") }
                }
                #if !os(tvOS)
                .buttonStyle(.borderedProminent)
                .tint(Theme.leaf)
                #endif
                .padding(.top, 6)
            }
        }
    }

    private func summary(_ album: LibraryItem, tracks: [LibraryFile]) -> String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(tracks.count) bài")
        let formats = Array(Set(tracks.compactMap { $0.badges.first })).sorted()
        if !formats.isEmpty { parts.append(formats.joined(separator: " / ")) }
        let bytes = tracks.reduce(Int64(0)) { $0 + $1.size }
        parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func playAlbum(_ album: LibraryItem, tracks: [LibraryFile], from position: Int) {
        let queue = PlaybackFactory.library(tracks, item: album, context: context)
        guard !queue.isEmpty else { return }
        play(PlaybackSession(items: queue, startIndex: min(position, queue.count - 1)))
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
    let played: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
            Text(title).font(.body).lineLimit(1)
            Spacer(minLength: 8)
            if played { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.leaf) }
            if let format { Text(format).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
