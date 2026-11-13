import ImageIO
import SwiftUI

/// TMDb / Trakt image or a picture made on the device, with a branded placeholder.
/// Not AsyncImage: it never retried, so a tile whose picture was still being made at launch stayed blank until
/// the page was opened again, and it decoded every 1280 px frame at full size.
struct ArtworkImage: View {
    let path: String?
    var size = "w500"
    var placeholderIcon = "film"

    @State private var loaded: CGImage?
    @State private var loadedKey: String?
    @State private var missingKey: String?
    @State private var attempt = 0

    var body: some View {
        let url = TMDbClient.imageURL(path, size: size)
        let key = url.map { ArtworkLoader.key($0, maxPixel: maxPixel) }
        let image = loadedKey == key ? loaded : nil
        let shown = image ?? key.flatMap(ArtworkLoader.cached)
        // The gradient takes the offered size; the image only fills it (a 16:9 video frame in a portrait
        // poster slot must not widen the card or spill over its neighbours).
        LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
            .overlay {
                if let shown {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if url == nil || missingKey == key {
                    placeholder
                }
            }
            .clipped()
            // Clipping only affects drawing: keep taps and the accessibility frame inside the slot too.
            .contentShape(Rectangle())
            .accessibilityHidden(true)
            .task(id: "\(key ?? "")#\(attempt)") {
                guard let url, let key else { return }
                // Another tile may have loaded it since this body ran: show it (returning early left it blank).
                if let cached = ArtworkLoader.cached(key) {
                    loaded = cached
                    loadedKey = key
                    return
                }
                let image = await ArtworkLoader.shared.load(url, maxPixel: maxPixel)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    loaded = image
                    loadedKey = key
                    missingKey = image == nil ? key : nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .xtArtworkWritten)) { note in
                // A picture made on the device just now (at launch, after the system emptied the cache, or for
                // a new file): show it in place of the placeholder.
                guard shown == nil, let name = note.object as? String, url?.isFileURL == true,
                      url?.lastPathComponent == name else { return }
                attempt += 1
            }
    }

    /// Pixels for the slot the size names (twice its points: Retina Macs and the Apple TV's 4K output).
    private var maxPixel: Int {
        switch size {
        case "blur": return 64
        case "w92": return 184
        case "w154", "w185": return 370
        case "w300", "w342": return 700
        case "w500": return 1000
        case "w780": return 1280
        default: return 1920
        }
    }

    private var placeholder: some View {
        Image(systemName: placeholderIcon)
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(Theme.brandGradient)
    }
}

/// Decodes artwork once, at the size it is shown, and keeps it in memory. Local pictures are read straight
/// from disk; remote ones go through URLSession (and its URLCache).
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    nonisolated(unsafe) private static let memory: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()

    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    static func key(_ url: URL, maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    static func cached(_ key: String) -> CGImage? { memory.object(forKey: key as NSString) }

    func load(_ url: URL, maxPixel: Int) async -> CGImage? {
        let key = Self.key(url, maxPixel: maxPixel)
        if let image = Self.cached(key) { return image }
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            let source: CGImageSource?
            if url.isFileURL {
                source = CGImageSourceCreateWithURL(url as CFURL, nil)
            } else {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
                source = CGImageSourceCreateWithData(data as CFData, nil)
            }
            guard let source else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { Self.memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height) }
        return image
    }
}

struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Theme.leaf).frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 4)
    }
}

/// 2:3 poster with title underneath (Infuse-style library tile).
struct PosterCard: View {
    let item: LibraryItem
    var progress: Double?
    var watched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(path: item.posterPath, size: "w342", placeholderIcon: Self.icon(item.kind))
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: Theme.posterWidth, height: Theme.posterWidth * 1.5)
                .overlay(alignment: .topTrailing) {
                    if watched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Theme.leaf)
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress { ProgressLine(value: progress).padding(8) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            #if !os(tvOS)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let year = item.year {
                    Text(String(year)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: Theme.posterWidth, alignment: .leading)
            #endif
        }
    }
}

extension PosterCard {
    static func icon(_ kind: LibraryKind) -> String {
        switch kind {
        case .movie: return "film"
        case .show: return "tv"
        case .musicVideo: return "music.note.tv"
        case .album: return "music.note"
        }
    }
}

/// Poster that opens the detail page, with progress / watched state.
struct PosterLink: View {
    let item: LibraryItem
    let index: LibraryIndex

    var body: some View {
        let state = index.progress(of: item)
        NavigationLink(value: item.kind == .album ? Route.album(itemKey: item.key) : Route.detail(itemKey: item.key)) {
            PosterCard(item: item, progress: state.progress, watched: state.watched)
        }
        .tileButtonStyle()
    }
}

/// 16:9 card for Continue Watching and episodes.
struct LandscapeCard: View {
    let title: String
    let subtitle: String?
    let imagePath: String?
    var progress: Double?
    var icon = "film"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(path: imagePath, size: "w780", placeholderIcon: icon)
                .frame(width: Theme.landscapeWidth, height: Theme.landscapeWidth * 9 / 16)
                .overlay(alignment: .bottom) {
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if let subtitle {
                                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                            if let progress { ProgressLine(value: progress) }
                        }
                        .foregroundStyle(.white)
                        .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// A titled horizontal row ("Tiếp tục xem", "Phim", …).
struct ShelfRow<Content: View>: View {
    let title: String
    var seeAll: Route?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title2.weight(.bold))
                Spacer()
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        Text("Xem tất cả").font(.callout.weight(.semibold))
                    }
                    #if !os(tvOS)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.leaf)
                    #endif
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Self.spacing) {
                    content()
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, Self.verticalPadding)
            }
            .scrollClipDisabled()
        }
    }

    #if os(tvOS)
    private static var spacing: CGFloat { 48 }
    private static var verticalPadding: CGFloat { 30 }
    #else
    private static var spacing: CGFloat { 16 }
    private static var verticalPadding: CGFloat { 4 }
    #endif
}

/// Applies the platform's tile button look (tvOS focus card, plain elsewhere).
struct TileButtonStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content.buttonStyle(.card)
        #else
        content.buttonStyle(.plain)
        #endif
    }
}

extension View {
    func tileButtonStyle() -> some View { modifier(TileButtonStyleModifier()) }
}

