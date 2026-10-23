import SwiftUI

/// TMDb image with a branded placeholder.
struct ArtworkImage: View {
    let path: String?
    var size = "w500"
    var placeholderIcon = "film"

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
            if let url = TMDbClient.imageURL(path, size: size) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        Color.clear
                    }
                }
            } else {
                placeholder
            }
        }
        .clipped()
    }

    private var placeholder: some View {
        Image(systemName: placeholderIcon)
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(Theme.brandGradient)
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
            ArtworkImage(path: item.posterPath, size: "w342", placeholderIcon: item.kind == .show ? "tv" : "film")
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

/// Poster that opens the detail page, with progress / watched state.
struct PosterLink: View {
    let item: LibraryItem
    let index: LibraryIndex

    var body: some View {
        let state = index.progress(of: item)
        NavigationLink(value: Route.detail(itemKey: item.key)) {
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
