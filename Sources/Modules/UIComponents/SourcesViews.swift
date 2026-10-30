import SwiftData
import SwiftUI

/// Keeps one live connection per server while browsing (SMB login is not free).
@MainActor
final class RemoteFileSystemPool {
    static let shared = RemoteFileSystemPool()
    private var pool: [String: (credentials: ServerCredentials, fs: RemoteFileSystem)] = [:]

    func fileSystem(for server: ServerCredentials) -> RemoteFileSystem {
        if let cached = pool[server.id], cached.credentials == server { return cached.fs }
        if let stale = pool[server.id] { Task { await stale.fs.close() } }
        let fs = RemoteFileSystems.make(server)
        pool[server.id] = (server, fs)
        return fs
    }

    func reset(_ serverID: String) {
        if let entry = pool.removeValue(forKey: serverID) { Task { await entry.fs.close() } }
    }
}

struct BrowserView: View {
    let serverID: String
    let path: String
    let title: String

    @Environment(\.modelContext) private var context
    @Environment(\.play) private var play
    @EnvironmentObject private var scanner: LibraryScanner
    @Query private var folders: [LibraryFolder]
    @State private var items: [RemoteItem] = []
    @State private var resolvedServer: ServerCredentials?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if !path.isEmpty {
                Section {
                    Button(action: toggleLibrary) {
                        Label(isLibraryFolder ? "Đã có trong thư viện — quét lại" : "Thêm thư mục này vào thư viện",
                              systemImage: isLibraryFolder ? "arrow.triangle.2.circlepath" : "rectangle.stack.badge.plus")
                    }
                    .disabled(scanner.isScanning)
                    if scanner.isScanning || !scanner.status.isEmpty {
                        Text(scanner.lastError ?? scanner.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if loading {
                HStack { ProgressView(); Text("Đang tải…").foregroundStyle(.secondary) }
            } else if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger)
                    Button("Thử lại") { Task { await load(reconnect: true) } }
                }
            } else if items.isEmpty {
                Text("Thư mục trống").foregroundStyle(.secondary)
            }
            ForEach(directories) { item in
                NavigationLink(value: Route.browser(serverID: serverID, path: item.path, title: item.name)) {
                    Label(item.name, systemImage: path.isEmpty ? "externaldrive.fill" : "folder.fill")
                }
            }
            ForEach(videos) { item in
                Button { playFile(item) } label: {
                    HStack(spacing: 12) {
                        if let resolvedServer {
                            BrowserThumbnail(server: resolvedServer, item: item)
                        } else {
                            Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.leaf)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(2)
                            Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .pageTitle(title)
        .task { await load(reconnect: false) }
    }

    // MARK: Data

    private var server: ServerCredentials? { PlaybackFactory.server(id: serverID, context: context) }
    private var directories: [RemoteItem] { items.filter(\.isDirectory).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var videos: [RemoteItem] { items.filter(\.isVideo).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var subtitles: [RemoteItem] { items.filter(\.isSubtitle) }
    private var isLibraryFolder: Bool { folders.contains { $0.serverID == serverID && $0.path == path } }

    private func detail(_ item: RemoteItem) -> String {
        let parsed = FilenameParser.parse(item.name)
        var parts = [ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)]
        parts.append(contentsOf: parsed.badges)
        return parts.joined(separator: " · ")
    }

    private func load(reconnect: Bool) async {
        guard let server else {
            error = "Không tìm thấy máy chủ."
            loading = false
            return
        }
        if reconnect { RemoteFileSystemPool.shared.reset(serverID) }
        resolvedServer = server
        loading = true
        error = nil
        do {
            items = try await RemoteFileSystemPool.shared.fileSystem(for: server).list(path)
        } catch {
            self.error = "Không mở được: \(error.localizedDescription)"
            RemoteFileSystemPool.shared.reset(serverID)
        }
        loading = false
    }

    private func playFile(_ item: RemoteItem) {
        guard let server else { return }
        let queue = PlaybackFactory.remote(files: videos, subtitles: subtitles, server: server, context: context)
        let index = videos.firstIndex(of: item) ?? 0
        guard !queue.isEmpty else { return }
        play(PlaybackSession(items: queue, startIndex: index))
    }

    private func toggleLibrary() {
        let key = "\(serverID):\(path)"
        let folder: LibraryFolder
        if let existing = folders.first(where: { $0.key == key }) {
            folder = existing
        } else {
            folder = LibraryFolder(serverID: serverID, path: path, name: title)
            context.insert(folder)
            try? context.save()
        }
        Task { await scanner.scan(folder: folder, context: context) }
    }
}

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @StateObject private var discovery = ServerDiscovery()

    @State private var kind: ServerKind = .smb
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var useTLS = true
    @State private var basePath = "/"
    @State private var allowInsecure = true
    @State private var testing = false
    @State private var message: String?
    @State private var failedOnce = false

    var body: some View {
        Form {
            if !discovery.servers.isEmpty {
                Section("Tìm thấy trong mạng") {
                    ForEach(discovery.servers) { found in
                        Button { Task { await pick(found) } } label: {
                            Label(found.name, systemImage: found.kind.icon)
                        }
                    }
                }
            }
            Section("Loại máy chủ") {
                Picker("Giao thức", selection: $kind) {
                    ForEach(ServerKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Địa chỉ") {
                TextField("Tên hiển thị (tuỳ chọn)", text: $name)
                TextField("Máy chủ — IP hoặc tên, ví dụ 192.168.1.10", text: $host)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField(kind == .smb ? "Cổng (mặc định 445)" : "Cổng (mặc định 80/443)", text: $port)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
                if kind == .webdav {
                    Toggle("HTTPS", isOn: $useTLS)
                    TextField("Đường dẫn gốc, ví dụ /dav", text: $basePath)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Toggle("Chấp nhận chứng chỉ tự ký", isOn: $allowInsecure)
                }
            }
            Section("Đăng nhập") {
                TextField("Tên đăng nhập (trống = khách)", text: $username)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Mật khẩu", text: $password)
                if kind == .smb {
                    TextField("Domain / Workgroup (tuỳ chọn)", text: $domain)
                        .autocorrectionDisabled()
                }
            }
            Section {
                Button(action: { Task { await save(force: false) } }) {
                    HStack {
                        if testing { ProgressView() }
                        Text(testing ? "Đang kiểm tra…" : "Kiểm tra kết nối & lưu")
                    }
                }
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                if failedOnce {
                    Button("Vẫn lưu (bỏ qua kiểm tra)") { Task { await save(force: true) } }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(failedOnce ? Theme.danger : Theme.leaf)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .pageTitle("Thêm máy chủ")
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func pick(_ found: DiscoveredServer) async {
        kind = found.kind
        name = found.name
        host = await ServerDiscovery.resolveHost(found)
        if kind == .webdav, case let .service(_, type, _, _) = found.endpoint { useTLS = type.contains("webdavs") }
    }

    private func save(force: Bool) async {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }
        var cleanedPath = basePath.trimmingCharacters(in: .whitespaces)
        if cleanedPath.isEmpty { cleanedPath = "/" }
        if !cleanedPath.hasPrefix("/") { cleanedPath = "/" + cleanedPath }
        let server = MediaServer(
            name: name.isEmpty ? trimmedHost : name, kind: kind, host: trimmedHost, port: Int(port) ?? 0,
            username: username.trimmingCharacters(in: .whitespaces), domain: domain, useTLS: useTLS,
            basePath: cleanedPath, allowInsecureTLS: allowInsecure
        )
        server.setPassword(password)
        if !force {
            testing = true
            message = nil
            let fs = RemoteFileSystems.make(server.credentials)
            do {
                let root = try await fs.list("")
                await fs.close()
                message = "Kết nối thành công — \(root.count) mục."
                failedOnce = false
            } catch {
                await fs.close()
                testing = false
                failedOnce = true
                message = "Không kết nối được: \(error.localizedDescription)"
                Keychain.set(nil, account: "server.\(server.id)")
                return
            }
            testing = false
        } else {
            server.setPassword(password)
        }
        context.insert(server)
        try? context.save()
        dismiss()
    }
}

/// "Nguồn": servers, library folders and quick open actions — Infuse's "Shares" screen.
struct SourcesView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var scanner: LibraryScanner
    @Query(sort: \MediaServer.createdAt) private var servers: [MediaServer]
    @Query(sort: \LibraryFolder.name) private var folders: [LibraryFolder]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                section("Máy chủ") {
                    ForEach(servers) { server in
                        NavigationLink(value: Route.browser(serverID: server.id, path: "", title: server.name)) {
                            SourceCard(icon: server.kind.icon, title: server.name,
                                       subtitle: "\(server.kind == .smb ? "SMB" : "WebDAV") · \(server.displayHost)")
                        }
                        .tileButtonStyle()
                        .contextMenu {
                            Button(role: .destructive) { Self.remove(server, context: context) } label: {
                                Label("Xoá máy chủ", systemImage: "trash")
                            }
                        }
                    }
                    NavigationLink(value: Route.addServer) {
                        SourceCard(icon: "plus.circle.fill", title: "Thêm máy chủ", subtitle: "SMB / WebDAV — tự tìm NAS trong mạng")
                    }
                    .tileButtonStyle()
                }

                section("Mở nhanh") {
                    #if !os(tvOS)
                    Button {
                        NotificationCenter.default.post(name: .xtOpenFileRequested, object: nil)
                    } label: {
                        SourceCard(icon: "film.stack", title: "Mở tệp video", subtitle: "MKV, MP4, TS, M2TS, ISO trên thiết bị")
                    }
                    .tileButtonStyle()
                    #endif
                    Button {
                        NotificationCenter.default.post(name: .xtOpenURLRequested, object: nil)
                    } label: {
                        SourceCard(icon: "link", title: "Mở URL", subtitle: "HTTP(S), HLS, FTP, RTSP")
                    }
                    .tileButtonStyle()
                }

                if !folders.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Thư mục thư viện").font(.title2.weight(.bold))
                            Spacer()
                            Button {
                                Task { await scanner.scanAll(context: context) }
                            } label: {
                                Label(scanner.isScanning ? "Đang quét…" : "Quét lại tất cả", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(scanner.isScanning)
                        }
                        if scanner.isScanning || scanner.lastError != nil {
                            Text(scanner.lastError ?? scanner.status)
                                .font(.footnote)
                                .foregroundStyle(scanner.lastError == nil ? Color.secondary : Theme.danger)
                        }
                        ForEach(folders) { folder in
                            NavigationLink(value: Route.browser(serverID: folder.serverID, path: folder.path, title: folder.name)) {
                                SourceCard(icon: "folder.fill", title: folder.name, subtitle: folderDetail(folder))
                            }
                            .tileButtonStyle()
                            .contextMenu {
                                Button {
                                    Task { await scanner.scan(folder: folder, context: context) }
                                } label: { Label("Quét lại", systemImage: "arrow.clockwise") }
                                Button(role: .destructive) { Self.remove(folder, context: context) } label: {
                                    Label("Bỏ khỏi thư viện", systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                }
            }
            .padding(.vertical, Theme.pagePadding / 2)
        }
        .pageTitle("Nguồn")
        .background(AppBackground())
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.cardMinWidth), spacing: Self.spacing)],
                      alignment: .leading, spacing: Self.spacing) {
                content()
            }
        }
        .padding(.horizontal, Theme.pagePadding)
    }

    private func folderDetail(_ folder: LibraryFolder) -> String {
        let server = servers.first { $0.id == folder.serverID }?.name ?? "?"
        var parts = [server, "\(folder.fileCount) tệp"]
        if let last = folder.lastScan { parts.append("quét " + last.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    // MARK: Maintenance

    static func remove(_ folder: LibraryFolder, context: ModelContext) {
        let folderKey = folder.key
        let files = (try? context.fetch(FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.folderKey == folderKey }))) ?? []
        files.forEach { context.delete($0) }
        context.delete(folder)
        pruneOrphans(context: context)
        try? context.save()
    }

    static func remove(_ server: MediaServer, context: ModelContext) {
        let id = server.id
        let owned = (try? context.fetch(FetchDescriptor<LibraryFolder>(predicate: #Predicate { $0.serverID == id }))) ?? []
        for folder in owned {
            let folderKey = folder.key
            let files = (try? context.fetch(FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.folderKey == folderKey }))) ?? []
            files.forEach { context.delete($0) }
            context.delete(folder)
        }
        Keychain.set(nil, account: "server.\(id)")
        RemoteFileSystemPool.shared.reset(id)
        context.delete(server)
        pruneOrphans(context: context)
        try? context.save()
    }

    /// Drops movies / shows that no longer have any file.
    private static func pruneOrphans(context: ModelContext) {
        try? context.save()
        let remaining = Set(((try? context.fetch(FetchDescriptor<LibraryFile>())) ?? []).map(\.itemKey))
        for item in (try? context.fetch(FetchDescriptor<LibraryItem>())) ?? [] where !remaining.contains(item.key) {
            context.delete(item)
        }
    }

    #if os(tvOS)
    private static let spacing: CGFloat = 40
    #else
    private static let spacing: CGFloat = 16
    #endif
}
