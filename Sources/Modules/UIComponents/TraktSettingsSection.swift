import SwiftData
import SwiftUI

/// Settings ▸ Trakt: the user's Trakt API application, device-code login, sync and scrobble switches.
struct TraktSettingsSection: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @ObservedObject private var trakt = TraktService.shared
    @AppStorage(TraktService.scrobbleKey) private var scrobble = true
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var showAppFields = false

    var body: some View {
        Section {
            switch trakt.phase {
            case .connected:
                LabeledContent("Tài khoản", value: trakt.username.isEmpty ? "Đã kết nối" : trakt.username)
                Toggle("Scrobble khi xem (đánh dấu đã xem từ 80 %)", isOn: $scrobble)
                Button {
                    Task { await trakt.sync(context: context) }
                } label: {
                    Label(trakt.isSyncing ? "Đang đồng bộ…" : "Đồng bộ ngay", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(trakt.isSyncing)
                Button("Ngắt kết nối Trakt", role: .destructive) { trakt.disconnect() }
            case let .awaitingCode(code, url):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mở \(url) trên điện thoại hoặc máy tính và nhập mã:")
                    Text(code)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        #if !os(tvOS)
                        .textSelection(.enabled)
                        #endif
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Đang chờ xác nhận…").foregroundStyle(.secondary)
                    }
                }
                #if !os(tvOS)
                if let link = URL(string: url) {
                    Button("Mở trang kích hoạt") { openURL(link) }
                }
                #endif
                Button("Huỷ") { trakt.cancelLogin() }
            case .disconnected:
                if trakt.hasAppCredentials && !showAppFields {
                    Button {
                        trakt.startLogin(context: context)
                    } label: {
                        Label("Kết nối Trakt", systemImage: "link")
                    }
                    Button("Đổi Client ID") { showAppFields = true }
                } else {
                    TextField("Client ID", text: $clientID)
                        .autocorrectionDisabled()
                    SecureField("Client Secret (để trống nếu Trakt ghi “Chưa được phát hành”)", text: $clientSecret)
                    Button("Lưu ứng dụng Trakt") {
                        Keychain.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), account: "trakt.clientID")
                        Keychain.set(clientSecret.trimmingCharacters(in: .whitespacesAndNewlines), account: "trakt.clientSecret")
                        showAppFields = false
                    }
                    .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !trakt.status.isEmpty {
                Text(trakt.status).font(.footnote).foregroundStyle(.secondary)
            }
            if let lastSync = trakt.lastSync {
                Text("Đồng bộ lần cuối: \(lastSync.formatted(date: .omitted, time: .shortened)) · tự đồng bộ khi mở app, khi đóng trình phát và mỗi 15 phút")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Trakt")
        } footer: {
            Text("Đồng bộ đã xem và điểm xem tiếp giữa Mac, iPhone, Apple TV (và Infuse nếu cũng nối Trakt). Chỉ phim và tập phim có trên Trakt mới đồng bộ được — video ca nhạc, concert, video gia đình thì không. Lỗi gửi lên Trakt (nếu có) nằm trong Nhật ký trình phát (dòng [trakt]). Bản tự build không kèm Client ID: tạo ứng dụng tại trakt.tv/oauth/applications/new (Redirect URI: http://localhost) rồi dán Client ID ở trên.")
        }
        .onAppear {
            clientID = Keychain.get(account: "trakt.clientID") ?? ""
            clientSecret = Keychain.get(account: "trakt.clientSecret") ?? ""
        }
    }
}
