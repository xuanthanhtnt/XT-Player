import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    let onPlay: (PlaybackSession) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \MediaEntry.lastPlayedAt, order: .reverse) private var recents: [MediaEntry]
    @State private var showImporter = false
    @State private var showURLSheet = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header
                    actions
                    if recents.isEmpty {
                        emptyState
                    } else {
                        recentSection
                    }
                    footer
                }
                .padding(Theme.pagePadding)
                .frame(maxWidth: 1600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppBackground())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        #if !os(tvOS)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.playableTypes, allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { open(MediaSource.pickedFile(url)) }
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
                open(source)
            }
        }
        .alert("Không mở được", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 18) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: headerMark, height: headerMark)
                .shadow(color: Theme.red.opacity(0.45), radius: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text("XT-Player")
                    .font(.system(size: headerTitle, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.brandGradient)
                Text("4K · HDR10 · Dolby Vision · Lossless Audio")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.cardMinWidth), spacing: 20)], alignment: .leading, spacing: 20) {
            #if !os(tvOS)
            ActionCard(icon: "film.stack", title: "Mở tệp video", subtitle: "MKV, MP4, TS, M2TS… phát trực tiếp từ thiết bị") {
                showImporter = true
            }
            #endif
            ActionCard(icon: "network", title: "Mở URL / NAS", subtitle: "HTTP, HTTPS, FTP, RTSP từ NAS hoặc máy chủ media") {
                showURLSheet = true
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Xem gần đây")
                .font(.title2.weight(.bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.cardMinWidth), spacing: 24)], alignment: .leading, spacing: 24) {
                ForEach(recents) { entry in
                    Button { reopen(entry, fromStart: false) } label: {
                        RecentCard(entry: entry)
                    }
                    #if os(tvOS)
                    .buttonStyle(.card)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .contextMenu {
                        if entry.resumePosition != nil {
                            Button { reopen(entry, fromStart: true) } label: { Label("Phát từ đầu", systemImage: "backward.end") }
                        }
                        Button(role: .destructive) {
                            context.delete(entry)
                            try? context.save()
                        } label: { Label("Xoá khỏi danh sách", systemImage: "trash") }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chưa có gì ở đây")
                .font(.headline)
            #if os(tvOS)
            Text("Nhập URL của một tệp phim trên NAS (HTTP/WebDAV) để bắt đầu. Duyệt SMB/WebDAV trực tiếp sẽ có ở v0.2.")
                .foregroundStyle(.secondary)
            #else
            Text("Mở một tệp 4K HDR10 hoặc Dolby Vision để thử lõi phát libmpv. Duyệt NAS qua SMB/WebDAV sẽ có ở v0.2.")
                .foregroundStyle(.secondary)
            #endif
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var footer: some View {
        Text("v\(Self.version) · libmpv \(Self.engineVersion) · VideoToolbox")
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }

    // MARK: Actions

    private func open(_ source: MediaSource) {
        let entry = MediaLibrary.touch(source, in: context)
        try? context.save()
        onPlay(PlaybackSession(source: source, title: entry.title, startAt: entry.resumePosition, entry: entry))
    }

    private func reopen(_ entry: MediaEntry, fromStart: Bool) {
        guard let source = MediaSource.restore(urlString: entry.urlString, bookmark: entry.bookmark) else {
            errorMessage = "Không tìm thấy tệp. Hãy mở lại từ trình chọn tệp."
            return
        }
        if source.bookmark != entry.bookmark, let fresh = source.bookmark { entry.bookmark = fresh }
        entry.lastPlayedAt = .now
        try? context.save()
        onPlay(PlaybackSession(source: source, title: entry.title, startAt: fromStart ? nil : entry.resumePosition, entry: entry))
    }

    // MARK: Constants

    #if os(tvOS)
    private let headerMark: CGFloat = 120
    private let headerTitle: CGFloat = 76
    #else
    private let headerMark: CGFloat = 64
    private let headerTitle: CGFloat = 40
    #endif

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    static let engineVersion = "0.41"

    static let playableTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .mpeg2TransportStream, .avi, .audio]
        for ext in ["mkv", "mka", "webm", "m2ts", "mts", "ts", "wmv", "flv", "vob", "iso", "rmvb", "ogm", "mpg", "mpeg"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()
}

private struct ActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
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
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

private struct RecentCard: View {
    let entry: MediaEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)], startPoint: .top, endPoint: .bottom)
                Image(systemName: entry.isLocalFile ? "film" : "network")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.brandGradient)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let progress = entry.progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Theme.brandGradient).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    .padding(10)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !entry.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(entry.tags.prefix(4), id: \.self) { TagChip(text: $0, highlighted: $0 == "DV" || $0.hasPrefix("HDR")) }
                    }
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        #if !os(tvOS)
        .glassPanel()
        .contentShape(Rectangle())
        #endif
    }

    private var statusLine: String {
        if entry.isWatched { return "Đã xem" }
        if let resume = entry.resumePosition {
            return "Tiếp tục từ \(TimeFormat.clock(resume))" + (entry.duration > 0 ? " / \(TimeFormat.clock(entry.duration))" : "")
        }
        return entry.lastPlayedAt.formatted(.relative(presentation: .named))
    }
}
