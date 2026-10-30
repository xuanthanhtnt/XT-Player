import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Looks for a newer XT-Player on GitHub Releases (CI publishes one per `v*` tag with the .dmg / .ipa files).
/// macOS downloads the DMG and opens it for a drag-to-Applications install (a sandboxed app cannot replace
/// itself); iOS opens the release page to sideload the new .ipa; tvOS can only tell the user.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repository = "xuanthanhtnt/XT-Player"

    struct Release: Equatable, Identifiable {
        var id: String { tag }
        let tag: String
        let version: String
        let notes: String
        let page: URL
        /// This platform's file (.dmg on macOS, the iOS / tvOS .ipa).
        let download: URL?
        let downloadSize: Int64
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case downloaded(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: Release?
    /// A newer version the user has not skipped: the app asks whether to update.
    @Published var prompt: Release?
    /// Result of a check started from the menu (nothing else on screen shows it).
    @Published var notice: String?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private static let lastCheckKey = "update.lastCheck"
    private static let skippedKey = "update.skippedVersion"

    /// At launch, at most about once a day.
    func checkIfDue() async {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool, announceResult: Bool = false) async {
        guard phase != .checking, phase != .downloading else { return }
        phase = .checking
        do {
            let release = try await fetchNewest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            latest = release
            if let release, Self.isNewer(release.version, than: Self.currentVersion) {
                phase = .available
                if userInitiated || UserDefaults.standard.string(forKey: Self.skippedKey) != release.version {
                    prompt = release
                }
            } else {
                phase = .upToDate
                if announceResult { notice = "Bạn đang dùng bản mới nhất (\(Self.currentVersion))." }
            }
        } catch {
            let text = "Không kiểm tra được bản cập nhật: \(error.localizedDescription)"
            phase = userInitiated ? .failed(text) : .idle
            if announceResult { notice = text }
        }
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
    }

    /// macOS: downloads the DMG and opens it. iOS: opens the release page. tvOS: nothing to open.
    func install(_ release: Release, openURL: (URL) -> Void) async {
        #if os(macOS)
        guard let download = release.download else { return openURL(release.page) }
        phase = .downloading
        do {
            let (temporary, response) = try await URLSession.shared.download(from: download)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw RemoteError.badResponse(http.statusCode)
            }
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Updates", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent("XT-Player-\(release.version).dmg")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            phase = .downloaded(target)
            NSWorkspace.shared.open(target)
            notice = "Đã mở bộ cài XT-Player \(release.version). Thoát app, kéo XT-Player vào Applications (chọn Thay thế) rồi mở lại."
        } catch {
            phase = .failed("Tải bản cập nhật thất bại: \(error.localizedDescription)")
        }
        #elseif os(iOS)
        openURL(release.page)
        #endif
    }

    #if os(macOS)
    /// After the DMG opened: quit so the copy in Applications can be replaced.
    func quitToInstall() {
        NSApp.terminate(nil)
    }
    #endif

    // MARK: GitHub

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int64
        }

        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool
        let assets: [Asset]
    }

    private func fetchNewest() async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=15") else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("XT-Player/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw RemoteError.badResponse(http.statusCode) }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data).filter { !$0.draft }
        return releases.map(Self.release).max { Self.isNewer($1.version, than: $0.version) }
    }

    private static func release(_ raw: GitHubRelease) -> Release {
        #if os(macOS)
        let asset = raw.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        #elseif os(tvOS)
        let asset = raw.assets.first { $0.name.hasSuffix(".ipa") && $0.name.contains("tvOS") }
        #else
        let asset = raw.assets.first { $0.name.hasSuffix(".ipa") && $0.name.contains("iOS") }
        #endif
        let version = raw.tag_name.hasPrefix("v") ? String(raw.tag_name.dropFirst()) : raw.tag_name
        return Release(tag: raw.tag_name, version: version, notes: raw.body ?? "", page: raw.html_url,
                       download: asset?.browser_download_url, downloadSize: asset?.size ?? 0)
    }

    /// Compares dotted versions numerically ("0.10.0" > "0.9.2"; suffixes such as "-beta" are ignored).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return trimmed.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}

/// Settings ▸ Cập nhật.
struct UpdateSection: View {
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            LabeledContent("Đang dùng", value: "\(UpdateChecker.currentVersion) (build \(UpdateChecker.currentBuild))")
            status
            Button {
                Task { await updates.check(userInitiated: true) }
            } label: {
                Label("Kiểm tra cập nhật", systemImage: "arrow.down.circle")
            }
            .disabled(updates.phase == .checking || updates.phase == .downloading)
        } header: {
            Text("Cập nhật")
        } footer: {
            Text("Bản mới lấy từ GitHub Releases của dự án. App tự kiểm tra mỗi ngày một lần khi mở.")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updates.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) { ProgressView(); Text("Đang kiểm tra…").foregroundStyle(.secondary) }
        case .upToDate:
            Label("Bạn đang dùng bản mới nhất", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.leaf)
        case .available:
            if let release = updates.latest {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Có bản \(release.version)").font(.headline)
                    if !release.notes.isEmpty {
                        Text(release.notes).font(.footnote).foregroundStyle(.secondary).lineLimit(6)
                    }
                }
                #if os(tvOS)
                Text("Cài bản mới bằng công cụ sideload (atvloadly, Xcode) hoặc TestFlight.").foregroundStyle(.secondary)
                #else
                Button {
                    Task { await updates.install(release) { openURL($0) } }
                } label: {
                    #if os(macOS)
                    Label(release.downloadSize > 0 ? "Tải và cài (\(ByteCountFormatter.string(fromByteCount: release.downloadSize, countStyle: .file)))" : "Tải và cài",
                          systemImage: "square.and.arrow.down")
                    #else
                    Label("Mở trang tải bản mới", systemImage: "safari")
                    #endif
                }
                #endif
            }
        case .downloading:
            HStack(spacing: 8) { ProgressView(); Text("Đang tải bản cập nhật…").foregroundStyle(.secondary) }
        case .downloaded:
            Text("Đã mở bộ cài. Thoát XT-Player, kéo XT-Player vào Applications (chọn Thay thế), rồi mở lại.")
                .foregroundStyle(.secondary)
            #if os(macOS)
            Button("Thoát để cài đặt") { updates.quitToInstall() }
            #endif
        case let .failed(message):
            Text(message).foregroundStyle(Theme.danger)
        }
    }
}

/// The "new version" prompt after the launch check (or the menu command), attached once at the root.
struct UpdatePromptModifier: ViewModifier {
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .task { await updates.checkIfDue() }
            .alert("Có bản XT-Player mới", isPresented: Binding(get: { updates.prompt != nil }, set: { if !$0 { updates.prompt = nil } }),
                   presenting: updates.prompt) { release in
                #if !os(tvOS)
                Button("Cập nhật") { Task { await updates.install(release) { openURL($0) } } }
                #endif
                Button("Bỏ qua bản này") { updates.skip(release) }
                Button("Để sau", role: .cancel) {}
            } message: { release in
                Text("Bản \(release.version) đã có (đang dùng \(UpdateChecker.currentVersion))."
                     + (release.notes.isEmpty ? "" : "\n\n" + String(release.notes.prefix(500))))
            }
            .alert("Cập nhật", isPresented: Binding(get: { updates.notice != nil }, set: { if !$0 { updates.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(updates.notice ?? "")
            }
    }
}
