import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.play) private var play
    @EnvironmentObject private var scanner: LibraryScanner
    @Query(sort: \LibraryItem.addedAt, order: .reverse) private var items: [LibraryItem]
    @Query(sort: \MediaEntry.lastPlayedAt, order: .reverse) private var entries: [MediaEntry]
    @Query(sort: \MediaServer.createdAt) private var servers: [MediaServer]
    @Query private var files: [LibraryFile]
    @State private var path: [Route] = []
    @State private var showImporter = false
    @State private var showURLSheet = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    header
                    if scanner.isScanning || scanner.lastError != nil { scanBanner }
                    if !continueWatching.isEmpty { continueRow }
                    if !movies.isEmpty {
                        ShelfRow(title: "Phim", seeAll: .grid(kind: LibraryKind.movie.rawValue)) {
                            ForEach(movies.prefix(24)) { posterLink($0) }
                        }
                    }
                    if !shows.isEmpty {
                        ShelfRow(title: "TV Shows", seeAll: .grid(kind: LibraryKind.show.rawValue)) {
                            ForEach(shows.prefix(24)) { posterLink($0) }
                        }
                    }
                    sources
                    if items.isEmpty { libraryHint }
                    footer
                }
                .padding(.vertical, Theme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppBackground())
            .navigationDestination(for: Route.self) { destination($0) }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        #if !os(tvOS)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.playableTypes, allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    play(PlaybackSession(item: PlaybackFactory.local(MediaSource.pickedFile(url), context: context)))
                }
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xtOpenFileRequested)) { _ in showImporter = true }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .xtOpenURLRequested)) { _ in showURLSheet = true }
        .sheet(isPresented: $showURLSheet) {
            OpenURLSheet { source in
                showURLSheet = false
                play(PlaybackSession(item: PlaybackFactory.local(source, context: context)))
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

    private var entriesByKey: [String: MediaEntry] {
        Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var continueWatching: [MediaEntry] {
        Array(entries.filter { $0.resumePosition != nil }.prefix(16))
    }

    private func itemProgress(_ item: LibraryItem) -> (progress: Double?, watched: Bool) {
        let byKey = entriesByKey
        let mine = files.filter { $0.itemKey == item.key }.compactMap { byKey[$0.key] }
        if item.kind == .movie {
            let best = mine.max { ($0.progress ?? 0) < ($1.progress ?? 0) }
            return (best?.resumePosition != nil ? best?.progress : nil, best?.isWatched ?? false)
        }
        let total = files.filter { $0.itemKey == item.key }.count
        let watched = mine.filter(\.isWatched).count
        return (nil, total > 0 && watched == total)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 18) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: Self.markSize, height: Self.markSize)
            VStack(alignment: .leading, spacing: 4) {
                Text("XT-Player")
                    .font(.system(size: Self.titleSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.brandGradient)
                Text("4K · HDR10 · Dolby Vision · Lossless Audio")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            NavigationLink(value: Route.settings) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    #if !os(tvOS)
                    .frame(width: 44, height: 44)
                    .glassPanel(cornerRadius: 22)
                    #endif
            }
            #if !os(tvOS)
            .buttonStyle(.plain)
            #endif
        }
        .padding(.horizontal, Theme.pagePadding)
    }

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

    private func posterLink(_ item: LibraryItem) -> some View {
        let state = itemProgress(item)
        return NavigationLink(value: Route.detail(itemKey: item.key)) {
            PosterCard(item: item, progress: state.progress, watched: state.watched)
        }
        .tileButtonStyle()
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nguồn").font(.title2.weight(.bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.cardMinWidth), spacing: 20)], alignment: .leading, spacing: 20) {
                ForEach(servers) { server in
                    NavigationLink(value: Route.browser(serverID: server.id, path: "", title: server.name)) {
                        SourceCard(icon: server.kind.icon, title: server.name,
                                   subtitle: "\(server.kind == .smb ? "SMB" : "WebDAV") · \(server.credentials.displayHost)")
                    }
                    .tileButtonStyle()
                }
                NavigationLink(value: Route.addServer) {
                    SourceCard(icon: "plus.circle.fill", title: "Thêm máy chủ", subtitle: "SMB / WebDAV — tự tìm NAS trong mạng")
                }
                .tileButtonStyle()
                #if !os(tvOS)
                Button { showImporter = true } label: {
                    SourceCard(icon: "film.stack", title: "Mở tệp video", subtitle: "MKV, MP4, TS, M2TS trên thiết bị")
                }
                .tileButtonStyle()
                #endif
                Button { showURLSheet = true } label: {
                    SourceCard(icon: "link", title: "Mở URL", subtitle: "HTTP, HTTPS, FTP, RTSP")
                }
                .tileButtonStyle()
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private var libraryHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tạo thư viện như Infuse").font(.headline)
            Text("Thêm máy chủ SMB/WebDAV, mở thư mục phim và chọn \"Thêm vào thư viện\". XT-Player tự nhận diện phim/tập và lấy poster, nội dung, diễn viên từ TMDb (nhập API key trong Cài đặt).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
        .padding(.horizontal, Theme.pagePadding)
    }

    private var footer: some View {
        Text("v\(Self.version) · libmpv 0.41 · VideoToolbox")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.pagePadding)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case let .grid(kind):
            LibraryGridView(kind: LibraryKind(rawValue: kind) ?? .movie)
        case let .detail(itemKey):
            MediaDetailView(itemKey: itemKey)
        case let .browser(serverID, path, title):
            BrowserView(serverID: serverID, path: path, title: title)
        case .addServer:
            AddServerView()
        case .settings:
            SettingsView()
        }
    }

    // MARK: Actions

    private func resume(_ entry: MediaEntry) {
        // An episode resumes with the rest of its season queued behind it.
        if let file = PlaybackFactory.libraryFile(key: entry.key, context: context),
           let item = items.first(where: { $0.key == file.itemKey }) {
            let siblings = files.filter { $0.itemKey == item.key }.sorted(by: LibraryOrdering.episodes)
            let queue = PlaybackFactory.library(siblings, item: item, context: context)
            if let index = queue.firstIndex(where: { $0.key == entry.key }) {
                play(PlaybackSession(items: queue, startIndex: index))
                return
            }
        }
        guard let item = PlaybackFactory.resume(entry, context: context) else {
            errorMessage = "Không tìm thấy tệp hoặc máy chủ. Hãy mở lại từ nguồn."
            return
        }
        play(PlaybackSession(item: item))
    }

    private func remaining(_ entry: MediaEntry) -> String? {
        guard entry.duration > 0 else { return nil }
        let left = max(0, entry.duration - entry.position)
        return "Còn \(TimeFormat.clock(left))"
    }

    // MARK: Constants

    #if os(tvOS)
    private static let markSize: CGFloat = 110
    private static let titleSize: CGFloat = 70
    #else
    private static let markSize: CGFloat = 60
    private static let titleSize: CGFloat = 38
    #endif

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2"

    static let playableTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .mpeg2TransportStream, .avi, .audio]
        for ext in ["mkv", "mka", "webm", "m2ts", "mts", "ts", "wmv", "flv", "vob", "iso", "rmvb", "ogm", "mpg", "mpeg"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()
}

enum LibraryOrdering {
    static func episodes(_ a: LibraryFile, _ b: LibraryFile) -> Bool {
        let sa = a.season ?? Int.max, sb = b.season ?? Int.max
        if sa != sb { return sa < sb }
        let ea = a.episode ?? Int.max, eb = b.episode ?? Int.max
        if ea != eb { return ea < eb }
        return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
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
