import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var scanner: LibraryScanner
    @Query(sort: \MediaServer.createdAt) private var servers: [MediaServer]
    @Query private var folders: [LibraryFolder]

    @AppStorage(AppSettings.hdrPassthrough) private var hdrPassthrough = true
    @AppStorage(AppSettings.audioPassthrough) private var audioPassthrough = false
    @AppStorage(AppSettings.deinterlace) private var deinterlace = "auto"
    @AppStorage(AppSettings.cacheMegabytes) private var cacheMegabytes = 400
    @AppStorage(AppSettings.autoplayNext) private var autoplayNext = true
    @AppStorage(AppSettings.subtitleLanguages) private var subtitleLanguages = "vi,vie,en,eng"
    @AppStorage(AppSettings.audioLanguages) private var audioLanguages = ""
    @AppStorage(AppSettings.subtitleScale) private var subtitleScale = 1.0
    @AppStorage(AppSettings.subtitlePosition) private var subtitlePosition = 100
    @AppStorage(AppSettings.subtitleBackground) private var subtitleBackground = false
    @AppStorage(AppSettings.metadataLanguage) private var metadataLanguage = "vi-VN"
    @State private var tmdbKey = ""
    @State private var tmdbSaved = false

    var body: some View {
        Form {
            Section {
                Toggle("HDR passthrough (HDR10 / HLG / Dolby Vision → PQ)", isOn: $hdrPassthrough)
                Picker("Khử xen kẽ (deinterlace)", selection: $deinterlace) {
                    Text("Tự động").tag("auto")
                    Text("Luôn bật").tag("yes")
                    Text("Tắt").tag("no")
                }
                Picker("Bộ đệm RAM", selection: $cacheMegabytes) {
                    ForEach(Self.cacheChoices, id: \.self) { Text("\($0) MB").tag($0) }
                }
                Toggle("Tự phát tập tiếp theo", isOn: $autoplayNext)
                #if os(tvOS)
                Text("Khớp tần số quét & dải động: bật Cài đặt ▸ Video và Âm thanh ▸ Khớp nội dung trên Apple TV.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
            } header: {
                Text("Phát lại")
            } footer: {
                Text("Áp dụng cho lần phát tiếp theo.")
            }

            Section("Âm thanh") {
                TextField("Ngôn ngữ âm thanh ưu tiên (vd: vie,eng)", text: $audioLanguages)
                    .autocorrectionDisabled()
                #if os(macOS)
                Toggle("Bitstream TrueHD / DTS-HD / E-AC3 qua HDMI (độc quyền)", isOn: $audioPassthrough)
                #endif
            }

            Section("Phụ đề") {
                TextField("Ngôn ngữ phụ đề ưu tiên", text: $subtitleLanguages)
                    .autocorrectionDisabled()
                Picker("Cỡ chữ", selection: $subtitleScale) {
                    ForEach(Self.scaleChoices, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
                Picker("Vị trí", selection: $subtitlePosition) {
                    Text("Sát đáy").tag(100)
                    Text("Cao hơn").tag(94)
                    Text("Giữa màn hình").tag(60)
                }
                Toggle("Nền tối sau chữ (.srt/.vtt)", isOn: $subtitleBackground)
            }

            Section {
                SecureField("TMDb API key (v3) hoặc Read Access Token (v4)", text: $tmdbKey)
                Button(tmdbSaved ? "Đã lưu" : "Lưu khoá TMDb") {
                    Keychain.set(tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "tmdb")
                    tmdbSaved = true
                }
                Picker("Ngôn ngữ thông tin phim", selection: $metadataLanguage) {
                    Text("Tiếng Việt").tag("vi-VN")
                    Text("English").tag("en-US")
                }
                Button {
                    Task { await scanner.scanAll(context: context) }
                } label: {
                    Label(scanner.isScanning ? scanner.status : "Quét lại toàn bộ thư viện", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(scanner.isScanning || folders.isEmpty)
            } header: {
                Text("Thư viện")
            } footer: {
                Text("Lấy khoá miễn phí tại themoviedb.org ▸ Settings ▸ API. \(folders.count) thư mục trong thư viện.")
            }

            Section("Máy chủ") {
                if servers.isEmpty { Text("Chưa có máy chủ").foregroundStyle(.secondary) }
                ForEach(servers) { server in
                    HStack {
                        Label(server.name, systemImage: server.kind.icon)
                        Spacer()
                        Text(server.displayHost).foregroundStyle(.secondary).font(.footnote)
                        Button(role: .destructive) { remove(server) } label: { Image(systemName: "trash") }
                            #if !os(tvOS)
                            .buttonStyle(.borderless)
                            #endif
                    }
                }
            }

            Section("Giới thiệu") {
                LabeledContent("Phiên bản", value: HomeView.version)
                LabeledContent("Lõi phát", value: "libmpv 0.41 · FFmpeg 9 · VideoToolbox")
                LabeledContent("SMB", value: "SMBClient (pure Swift, SMB2/3)")
            }
        }
        .navigationTitle("Cài đặt")
        .onAppear {
            tmdbKey = Keychain.get(account: "tmdb") ?? ""
        }
        .onChange(of: tmdbKey) { _, _ in tmdbSaved = false }
    }

    private func remove(_ server: MediaServer) {
        let id = server.id
        for folder in folders where folder.serverID == id {
            let folderKey = folder.key
            let files = (try? context.fetch(FetchDescriptor<LibraryFile>(predicate: #Predicate { $0.folderKey == folderKey }))) ?? []
            files.forEach { context.delete($0) }
            context.delete(folder)
        }
        // Drop movies / shows that no longer have any file.
        let remaining = Set(((try? context.fetch(FetchDescriptor<LibraryFile>())) ?? []).filter { $0.serverID != id }.map(\.itemKey))
        for item in (try? context.fetch(FetchDescriptor<LibraryItem>())) ?? [] where !remaining.contains(item.key) {
            context.delete(item)
        }
        Keychain.set(nil, account: "server.\(id)")
        RemoteFileSystemPool.shared.reset(id)
        context.delete(server)
        try? context.save()
    }

    private static let cacheChoices = [150, 250, 400, 600, 1024, 2048]
    private static let scaleChoices = [0.8, 0.9, 1.0, 1.15, 1.3, 1.5]
}
