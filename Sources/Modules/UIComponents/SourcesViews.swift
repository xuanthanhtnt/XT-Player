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
                    HStack {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.leaf)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(2)
                            Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
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
        .navigationTitle("Thêm máy chủ")
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
