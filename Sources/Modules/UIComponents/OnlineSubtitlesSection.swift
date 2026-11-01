import SwiftUI

/// Subtitles panel ▸ OpenSubtitles (like Infuse's "Search Online"): searches by the file's hash and its title,
/// a tap downloads the subtitle and shows it right away.
struct OnlineSubtitlesSection: View {
    @ObservedObject var engine: MPVPlayerEngine
    let title: String
    let onInteraction: () -> Void

    @State private var expanded = false
    @State private var query = ""
    @State private var results: [OpenSubtitlesClient.Subtitle] = []
    @State private var searching = false
    @State private var loadingID: String?
    @State private var message: String?

    var body: some View {
        PanelSection(title: "Phụ đề trực tuyến") {
            if expanded {
                HStack(spacing: 8) {
                    TextField("Tên phim / tập", text: $query)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .onSubmit { Task { await search() } }
                    Button("Tìm") { Task { await search() } }
                        .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 6)
                if searching {
                    HStack(spacing: 8) { ProgressView(); Text("Đang tìm…").font(.caption) }.padding(.horizontal, 8)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                ForEach(results.prefix(40)) { subtitle in
                    PanelChoice(text: subtitle.release, detail: detail(subtitle), selected: false) {
                        Task { await load(subtitle) }
                    }
                    .disabled(loadingID != nil)
                }
            } else {
                PanelChoice(text: "Tìm trên OpenSubtitles…", selected: false) {
                    expanded = true
                    if query.isEmpty { query = parsed.title }
                    Task { await search() }
                }
            }
        }
    }

    /// Title / year / episode recognised from the file name (more precise than the display title).
    private var parsed: ParsedMediaName {
        let location = engine.currentLocation
        let name = URL(string: location)?.lastPathComponent ?? (location as NSString).lastPathComponent
        let decoded = name.removingPercentEncoding ?? name
        return FilenameParser.parse(decoded.isEmpty ? title : decoded)
    }

    private func detail(_ subtitle: OpenSubtitlesClient.Subtitle) -> String {
        if loadingID == subtitle.id { return "Đang tải…" }
        var parts = [Locale.current.localizedString(forLanguageCode: subtitle.language) ?? subtitle.language.uppercased(),
                     "\(subtitle.downloads) lượt tải"]
        if subtitle.hashMatch { parts.append("khớp tệp") }
        if subtitle.hearingImpaired { parts.append("SDH") }
        if subtitle.machineTranslated { parts.append("máy dịch") }
        return parts.joined(separator: " · ")
    }

    private func search() async {
        guard let client = OpenSubtitlesClient.current() else {
            message = OpenSubtitlesClient.Failure.noKey.localizedDescription
            return
        }
        searching = true
        message = nil
        defer { searching = false }
        let info = parsed
        var season: Int?, episode: Int?
        if case let .episode(s, e) = info.kind {
            season = s
            episode = e
        }
        let location = engine.currentLocation
        let hash = await Task.detached(priority: .userInitiated) { OpenSubtitlesHash.compute(location: location) }.value
        let languages = (UserDefaults.standard.string(forKey: AppSettings.subtitleLanguages) ?? "vi,en")
            .split(separator: ",").map(String.init)
        do {
            let found = try await client.search(query: query.trimmingCharacters(in: .whitespaces), year: info.year,
                                                season: season, episode: episode, languages: languages, hash: hash)
            // Exact-release matches (by hash) first, then by popularity as the API ordered them.
            results = found.filter(\.hashMatch) + found.filter { !$0.hashMatch }
            if results.isEmpty { message = "Không tìm thấy phụ đề — thử sửa tên ở trên." }
        } catch {
            message = error.localizedDescription
        }
    }

    private func load(_ subtitle: OpenSubtitlesClient.Subtitle) async {
        guard let client = OpenSubtitlesClient.current() else { return }
        loadingID = subtitle.id
        message = nil
        defer { loadingID = nil }
        do {
            let file = try await client.download(subtitle)
            engine.addSubtitle(file.path)
            message = "Đã nạp: \(subtitle.release)"
            onInteraction()
        } catch {
            message = error.localizedDescription
        }
    }
}
