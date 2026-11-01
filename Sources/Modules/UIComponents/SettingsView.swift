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
    @AppStorage(AppSettings.hardwareDecoding) private var hardwareDecoding = true
    @AppStorage(AppSettings.pictureQuality) private var pictureQuality = PictureQuality.platformDefault.rawValue
    @AppStorage(AppSettings.motionSmoothing) private var motionSmoothing = false
    @AppStorage(AppSettings.matchSampleRate) private var matchSampleRate = false
    @AppStorage(AppSettings.nightMode) private var nightMode = false
    @AppStorage(AppSettings.dialogBoost) private var dialogBoost = false
    @AppStorage(AppSettings.volumeLeveling) private var volumeLeveling = false
    @State private var tmdbKey = ""
    @State private var openSubtitlesKey = ""
    @State private var openSubtitlesPassword = ""
    @State private var openSubtitlesSaved = false
    @AppStorage(AppSettings.openSubtitlesUser) private var openSubtitlesUser = ""
    @State private var tmdbSaved = false

    var body: some View {
        Form {
            Section {
                Picker("Chất lượng hình ảnh", selection: $pictureQuality) {
                    ForEach(PictureQuality.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Giải mã phần cứng (VideoToolbox)", isOn: $hardwareDecoding)
                Toggle("HDR passthrough (HDR10 / HLG / Dolby Vision → PQ)", isOn: $hdrPassthrough)
                #if !os(tvOS)
                Toggle("Chuyển động mượt (khử rung phim 24p)", isOn: $motionSmoothing)
                #endif
                Picker("Khử xen kẽ (deinterlace)", selection: $deinterlace) {
                    Text("Tự động").tag("auto")
                    Text("Luôn bật").tag("yes")
                    Text("Tắt").tag("no")
                }
            } header: {
                Text("Hình ảnh")
            } footer: {
                Text(Self.videoFooter(PictureQuality(rawValue: pictureQuality) ?? .platformDefault))
            }

            Section {
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

            Section {
                TextField("Ngôn ngữ âm thanh ưu tiên (vd: vie,eng)", text: $audioLanguages)
                    .autocorrectionDisabled()
                Toggle("Tăng thoại (nghe rõ lời nói)", isOn: $dialogBoost)
                Toggle("Chế độ ban đêm (nén dải động)", isOn: $nightMode)
                Toggle("Cân bằng âm lượng nhạc (ReplayGain)", isOn: $volumeLeveling)
                #if os(macOS)
                Toggle("Khớp tần số lấy mẫu với DAC / loa ngoài", isOn: $matchSampleRate)
                Toggle("Bitstream TrueHD / DTS-HD / E-AC3 qua HDMI", isOn: $audioPassthrough)
                    .disabled(!MPVPlayerEngine.bitstreamSupported)
                #endif
            } header: {
                Text("Âm thanh")
            } footer: {
                #if os(macOS)
                Text("Tăng thoại: kênh giữa to hơn, kênh vòm và siêu trầm nhỏ lại (stereo: tách dải giọng nói). Ban đêm: nén dải động — tiếng nói nhỏ được nâng lên, tiếng nổ được giữ lại — cộng thông tin nén có sẵn trong âm thanh Dolby. Khớp tần số: đổi tần số của thiết bị theo file (44,1 / 48 / 96 / 192 kHz), không để macOS lấy mẫu lại — bật khi dùng DAC hoặc loa ngoài để nghe hi-res đúng gốc (bảng Thông tin trong trình phát cho biết có lấy mẫu lại hay không). Cân bằng âm lượng: dùng thẻ ReplayGain trong file để các album to nhỏ như nhau (giữ chênh lệch giữa các bài trong album). Bitstream: gửi nguyên AC3 / E-AC3 / DTS (và TrueHD / DTS-HD MA nếu cổng HDMI của Mac nhận) cho ampli giải mã; thiết bị không nhận thì app tự giải mã lossless thành PCM.")
                #else
                Text("Tăng thoại: kênh giữa to hơn, kênh vòm và siêu trầm nhỏ lại (stereo: tách dải giọng nói). Ban đêm: nén dải động — tiếng nói nhỏ được nâng lên, tiếng nổ được giữ lại. Âm thanh hi-res (44,1–192 kHz) phát đúng tần số gốc khi cắm DAC USB / Lightning.")
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

            Section {
                ForEach(servers) { server in
                    HStack {
                        Label(server.name, systemImage: server.kind.icon)
                        Spacer()
                        Text(server.displayHost).foregroundStyle(.secondary).font(.footnote)
                        Button(role: .destructive) { SourcesView.remove(server, context: context) } label: { Image(systemName: "trash") }
                            #if !os(tvOS)
                            .buttonStyle(.borderless)
                            #endif
                    }
                }
                NavigationLink(value: Route.diagnostics) {
                    Label("Nhật ký trình phát (chẩn đoán)", systemImage: "stethoscope")
                }
            } header: {
                Text("Máy chủ & chẩn đoán")
            } footer: {
                Text("Nếu video không có tiếng / không phát: mở nhật ký ngay sau khi phát rồi bấm Sao chép để gửi lỗi.")
            }

            Section {
                SecureField("API key", text: $openSubtitlesKey)
                TextField("Tài khoản (không bắt buộc)", text: $openSubtitlesUser)
                    .autocorrectionDisabled()
                SecureField("Mật khẩu", text: $openSubtitlesPassword)
                Button(openSubtitlesSaved ? "Đã lưu" : "Lưu") {
                    Keychain.set(openSubtitlesKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "opensubtitles")
                    Keychain.set(openSubtitlesPassword, account: "opensubtitles.password")
                    openSubtitlesSaved = true
                }
            } header: {
                Text("Phụ đề trực tuyến (OpenSubtitles)")
            } footer: {
                Text("Lấy API key miễn phí tại opensubtitles.com ▸ Profile ▸ API Consumers. Đăng nhập tài khoản để được tải nhiều phụ đề hơn mỗi ngày. Tìm phụ đề trong trình phát ▸ bảng Phụ đề.")
            }

            TraktSettingsSection()

            UpdateSection()

            Section("Giới thiệu") {
                LabeledContent("Phiên bản", value: HomeView.version)
                LabeledContent("Lõi phát", value: "libmpv 0.41 · FFmpeg 9 · VideoToolbox")
                LabeledContent("SMB", value: "SMBClient (pure Swift, SMB2/3)")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #elseif os(tvOS)
        // tvOS opens a Form picker as a pushed list, and in the sidebar tab view that list came up empty (only
        // the blurred background, nothing focusable): a menu opens in place instead.
        .pickerStyle(.menu)
        #endif
        .pageTitle("Cài đặt")
        .onAppear {
            tmdbKey = Keychain.get(account: "tmdb") ?? ""
            openSubtitlesKey = Keychain.get(account: "opensubtitles") ?? ""
            openSubtitlesPassword = Keychain.get(account: "opensubtitles.password") ?? ""
        }
        .onChange(of: tmdbKey) { _, _ in tmdbSaved = false }
        .onChange(of: openSubtitlesKey) { _, _ in openSubtitlesSaved = false }
        .onChange(of: openSubtitlesPassword) { _, _ in openSubtitlesSaved = false }
    }

    private static func videoFooter(_ quality: PictureQuality) -> String {
        var text = "\(quality.label): \(quality.detail). Giải mã phần cứng tiết kiệm pin và CPU; tắt nếu video bị nhiễu hình hoặc sai màu (máy tự chuyển sang giải mã phần mềm với định dạng chip không hỗ trợ, như AV1 trên chip cũ)."
        #if !os(tvOS)
        text += " Chuyển động mượt: khớp từng khung với tần số màn hình và hoà trộn khung ở chỗ chuyển tiếp, hết giật khi phim 24 hình/giây chạy trên màn 60 Hz — không tạo hiệu ứng “phim truyền hình”."
        #endif
        return text
    }

    private static let cacheChoices = [150, 250, 400, 600, 1024, 2048]
    private static let scaleChoices = [0.8, 0.9, 1.0, 1.15, 1.3, 1.5]
}
