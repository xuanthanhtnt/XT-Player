import Foundation

/// What can be learned from a release-style file name, before any TMDb lookup.
struct ParsedMediaName: Equatable {
    enum Kind: Equatable {
        case movie
        case episode(season: Int, episode: Int)
    }

    var title: String
    var year: Int?
    var kind: Kind
    var resolution: String?
    var dynamicRange: [String]
    var audio: [String]

    /// "The Matrix (1999)" / "Severance · S02E05".
    var displayTitle: String {
        switch kind {
        case let .episode(season, episode):
            return "\(title) · S\(Self.twoDigits(season))E\(Self.twoDigits(episode))"
        case .movie:
            if let year { return "\(title) (\(year))" }
            return title
        }
    }

    private static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// Compact chips for the UI, e.g. ["4K", "DV", "HDR10", "TrueHD Atmos"].
    var badges: [String] {
        var out: [String] = []
        if let resolution { out.append(resolution) }
        out.append(contentsOf: dynamicRange)
        if let first = audio.first { out.append(first) }
        return out
    }
}

/// Splits scene / Plex / Kodi style names: "Movie.Title.2019.2160p.UHD.BluRay.REMUX.DV.HDR10.TrueHD.Atmos.7.1-GRP.mkv",
/// "Show Name - S01E02 - Episode.mkv", "Show.Name.1x02.mkv", "Movie Title (2019).mkv".
enum FilenameParser {
    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "ts", "m2ts", "mts", "webm", "flv", "iso", "mpg", "mpeg", "vob", "ogm", "rmvb",
    ]

    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi"]

    static func parse(_ rawName: String) -> ParsedMediaName {
        var name = rawName
        if let dot = name.lastIndex(of: "."), videoExtensions.contains(name[name.index(after: dot)...].lowercased()) {
            name = String(name[..<dot])
        }
        let lower = name.lowercased()

        var kind = ParsedMediaName.Kind.movie
        var titleEnd = name.endIndex
        var year: Int?

        if let m = firstMatch(#"(?i)(?:^|[\s._\-\[(])s(\d{1,2})[\s._\-]?e(\d{1,3})(?:[\s._\-]?e\d{1,3})*(?=$|[\s._\-\])])"#, in: name)
            ?? firstMatch(#"(?i)(?:^|[\s._\-\[(])(\d{1,2})x(\d{2,3})(?=$|[\s._\-\])])"#, in: name) {
            kind = .episode(season: Int(name[m.groups[0]]) ?? 0, episode: Int(name[m.groups[1]]) ?? 0)
            titleEnd = m.range.lowerBound
        }

        // Year: the last plausible 19xx/20xx token that is not at the very start (keeps "2001 A Space Odyssey 1968").
        let years = allMatches(#"(?:^|[\s._\-\[(])((?:19|20)\d{2})(?=$|[\s._\-\])])"#, in: name)
            .filter { $0.range.lowerBound > name.startIndex }
            .filter { $0.range.lowerBound < titleEnd || titleEnd == name.endIndex }
        if let y = years.last {
            year = Int(name[y.groups[0]])
            if y.range.lowerBound < titleEnd { titleEnd = y.range.lowerBound }
        }

        if titleEnd == name.endIndex,
           let q = firstMatch(#"(?i)(?:^|[\s._\-\[(])(?:2160p|1080p|1080i|720p|576p|480p|4k|uhd|bluray|blu-ray|bdremux|remux|bdrip|brrip|web-?dl|webrip|hdtv|dvdrip|x26[45]|h\.?26[45]|hevc|avc|hdr10|dovi)(?=$|[\s._\-\])])"#, in: name),
           q.range.lowerBound > name.startIndex {
            titleEnd = q.range.lowerBound
        }

        var title = String(name[..<titleEnd])
        title = replace(#"^\s*[\[(][^\])]*[\])]\s*"#, in: title, with: "")   // leading [Group] tag
        if !title.contains(" ") || title.filter({ $0 == "." || $0 == "_" }).count >= 2 {
            title = title.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        title = replace(#"\s+"#, in: title, with: " ")
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_.([{"))
        if title.isEmpty { title = name }

        return ParsedMediaName(
            title: title,
            year: year,
            kind: kind,
            resolution: resolution(in: lower),
            dynamicRange: dynamicRange(in: lower),
            audio: audio(in: lower)
        )
    }

    // MARK: - Tags

    private static func resolution(in s: String) -> String? {
        if has(#"2160p|4k|uhd"#, s) { return "4K" }
        if has(#"1080[pi]"#, s) { return "1080p" }
        if has(#"720p"#, s) { return "720p" }
        if has(#"576p|480p|dvdrip"#, s) { return "SD" }
        return nil
    }

    private static func dynamicRange(in s: String) -> [String] {
        var out: [String] = []
        if has(#"dv|dovi|dolby[\s._\-]?vision"#, s) { out.append("DV") }
        if has(#"hdr10\+|hdr10plus|hdr10p"#, s) {
            out.append("HDR10+")
        } else if has(#"hdr10|hdr"#, s) {
            out.append("HDR10")
        }
        if has(#"hlg"#, s) { out.append("HLG") }
        return out
    }

    private static func audio(in s: String) -> [String] {
        var out: [String] = []
        let atmos = has(#"atmos"#, s)
        if has(#"truehd"#, s) { out.append(atmos ? "TrueHD Atmos" : "TrueHD") }
        if has(#"dts[\s._\-]?x"#, s) {
            out.append("DTS:X")
        } else if has(#"dts[\s._\-]?hd(?:[\s._\-]?ma)?"#, s) {
            out.append("DTS-HD MA")
        } else if has(#"dts"#, s) {
            out.append("DTS")
        }
        if has(#"ddp|dd\+|eac3|e-ac-3"#, s) { out.append(atmos && !out.contains("TrueHD Atmos") ? "DD+ Atmos" : "DD+") }
        if has(#"ac3|dd5[\s._]?1|dd2[\s._]?0"#, s) { out.append("AC3") }
        if has(#"flac"#, s) { out.append("FLAC") }
        if out.isEmpty, has(#"aac"#, s) { out.append("AAC") }
        return out
    }

    // MARK: - Regex helpers (NSRegularExpression keeps this file portable and testable on any toolchain)

    private struct Match {
        let range: Range<String.Index>
        let groups: [Range<String.Index>]
    }

    private static func has(_ token: String, _ s: String) -> Bool {
        // Digits may follow a token directly ("DDP5.1", "AAC2.0", "DTS5.1").
        firstMatch("(?:^|[^a-z0-9])(?:\(token))(?=$|[^a-z])", in: s) != nil
    }

    private static func firstMatch(_ pattern: String, in s: String) -> Match? {
        allMatches(pattern, in: s).first
    }

    private static func allMatches(_ pattern: String, in s: String) -> [Match] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { r in
            guard let whole = Range(r.range, in: s) else { return nil }
            var groups: [Range<String.Index>] = []
            if r.numberOfRanges > 1 {
                for i in 1..<r.numberOfRanges {
                    if let g = Range(r.range(at: i), in: s) { groups.append(g) }
                }
            }
            // A leading separator belongs to the boundary, not the token.
            var start = whole.lowerBound
            if start < whole.upperBound, let ch = s[start...].first, " ._-[(".contains(ch), groups.first.map({ $0.lowerBound > start }) ?? true {
                start = s.index(after: start)
            }
            return Match(range: start..<whole.upperBound, groups: groups)
        }
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
