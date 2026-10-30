import SwiftUI

// The music player's views, after Roon: a bar along the bottom of the window while the library is browsed, a full
// Now Playing view (blurred cover, queue, signal path), and the queue itself.

/// The bar at the bottom of the window (Mac) or above the tab bar (iPhone / iPad).
struct MiniPlayerBar: View {
    @ObservedObject private var music = MusicPlayer.shared

    var body: some View {
        if let engine = music.engine, let current = music.current {
            MiniPlayerContent(engine: engine, item: current)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct MiniPlayerContent: View {
    @ObservedObject var engine: MPVPlayerEngine
    @ObservedObject private var music = MusicPlayer.shared
    let item: PlaybackItem

    var body: some View {
        HStack(spacing: 14) {
            Button { music.showsNowPlaying = true } label: {
                HStack(spacing: 12) {
                    ArtworkImage(path: item.artworkPath, size: "w185", placeholderIcon: "music.note")
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 300, alignment: .leading)
            #if os(macOS)
            Spacer(minLength: 12)
            VStack(spacing: 4) {
                HStack(spacing: 20) {
                    SignalPathDot(engine: engine)
                    MusicButton("backward.end.fill", size: 15) { music.previous() }
                    MusicButton(engine.state == .playing ? "pause.fill" : "play.fill", size: 22) { music.togglePause() }
                    MusicButton("forward.end.fill", size: 15) { music.next() }
                    MusicButton("list.bullet", size: 14) { music.showsNowPlaying = true }
                }
                SeekRow(engine: engine)
            }
            .frame(maxWidth: 480)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { engine.volume }, set: { engine.setVolume($0) }), in: 0...100)
                    .frame(width: 100)
                    .disabled(engine.isBitstreaming)
            }
            #else
            Spacer(minLength: 8)
            MusicButton(engine.state == .playing ? "pause.fill" : "play.fill", size: 22) { music.togglePause() }
            MusicButton("forward.end.fill", size: 18) { music.next() }
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) {
            #if os(iOS)
            // A hairline of progress along the bar's bottom edge, as in Music.
            GeometryReader { geo in
                Rectangle().fill(Theme.leaf)
                    .frame(width: geo.size.width * (engine.duration > 0 ? min(1, engine.position / engine.duration) : 0), height: 2)
            }
            .frame(height: 2)
            #endif
        }
    }
}

/// Elapsed · scrubber · remaining.
private struct SeekRow: View {
    @ObservedObject var engine: MPVPlayerEngine
    @State private var scrub: Double?

    var body: some View {
        HStack(spacing: 10) {
            Text(TimeFormat.clock(scrub ?? engine.position))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
            #if os(tvOS)
            ProgressView(value: engine.duration > 0 ? min(1, engine.position / engine.duration) : 0).tint(Theme.leaf)
            #else
            Slider(value: Binding(get: { scrub ?? engine.position }, set: { scrub = $0 }), in: 0...max(engine.duration, 1)) { editing in
                if !editing, let target = scrub {
                    engine.seek(to: target)
                    scrub = nil
                }
            }
            .tint(Theme.leaf)
            .controlSize(.small)
            #endif
            Text("-" + TimeFormat.clock(max(0, engine.duration - (scrub ?? engine.position))))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
        }
    }
}

private struct MusicButton: View {
    let icon: String
    let size: CGFloat
    let action: () -> Void

    init(_ icon: String, size: CGFloat, action: @escaping () -> Void) {
        self.icon = icon
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 18, height: size + 14)
                .contentShape(Rectangle())
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Now Playing

/// Full-window Now Playing: the cover on a blur of itself, title / album / artist, transport, signal path, queue.
struct MusicNowPlayingView: View {
    @ObservedObject private var music = MusicPlayer.shared

    var body: some View {
        if let engine = music.engine, let current = music.current {
            NowPlayingContent(engine: engine, item: current)
        } else {
            Color.black.onAppear { music.showsNowPlaying = false }
        }
    }
}

private struct NowPlayingContent: View {
    @ObservedObject var engine: MPVPlayerEngine
    @ObservedObject private var music = MusicPlayer.shared
    let item: PlaybackItem
    @State private var showsQueue = false

    var body: some View {
        ZStack {
            // Opaque underneath: a blur fades out at its edges and would let the library show through.
            Theme.background.ignoresSafeArea()
            ArtworkImage(path: item.artworkPath, size: "w780", placeholderIcon: "music.note")
                .blur(radius: 70)
                .overlay(Color.black.opacity(0.55))
                .ignoresSafeArea()
            GeometryReader { geo in
                let wide = geo.size.width > 900
                HStack(alignment: .center, spacing: 40) {
                    VStack(spacing: 22) {
                        Spacer(minLength: 0)
                        if showsQueue && !wide {
                            QueueList().frame(maxHeight: geo.size.height * 0.55)
                        } else {
                            ArtworkImage(path: item.artworkPath, size: "w780", placeholderIcon: "music.note")
                                .frame(width: cover(geo.size), height: cover(geo.size))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: .black.opacity(0.45), radius: 28, y: 12)
                        }
                        VStack(spacing: 6) {
                            Text(item.title).font(.title2.weight(.bold)).multilineTextAlignment(.center).lineLimit(2)
                            if let subtitle = item.subtitle {
                                Text(subtitle).font(.body).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                            }
                        }
                        SignalPathBadge(engine: engine)
                        SeekRow(engine: engine).frame(maxWidth: 560)
                        HStack(spacing: 30) {
                            MusicButton("shuffle", size: 17) { music.toggleShuffle() }
                                .foregroundStyle(music.isShuffled ? Theme.leaf : .white.opacity(0.75))
                            MusicButton("backward.end.fill", size: 22) { music.previous() }
                            MusicButton(engine.state == .playing ? "pause.circle.fill" : "play.circle.fill", size: 54) { music.togglePause() }
                            MusicButton("forward.end.fill", size: 22) { music.next() }
                            MusicButton(music.repeatMode == .one ? "repeat.1" : "repeat", size: 17) { music.cycleRepeat() }
                                .foregroundStyle(music.repeatMode == .off ? .white.opacity(0.75) : Theme.leaf)
                        }
                        #if os(macOS)
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").foregroundStyle(.white.opacity(0.6))
                            Slider(value: Binding(get: { engine.volume }, set: { engine.setVolume($0) }), in: 0...100)
                                .tint(.white).frame(width: 220)
                                .disabled(engine.isBitstreaming)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.white.opacity(0.6))
                        }
                        #endif
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    if showsQueue && wide {
                        QueueList()
                            .frame(width: min(420, geo.size.width * 0.38))
                            .padding(.vertical, 60)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 40)
            }
        }
        .foregroundStyle(.white)
        .overlay(alignment: .topLeading) {
            MusicButton("chevron.down", size: 18) { music.showsNowPlaying = false }
                .padding(.top, 20).padding(.leading, 20)
        }
        .overlay(alignment: .topTrailing) {
            MusicButton("list.bullet", size: 18) { withAnimation(.easeInOut(duration: 0.25)) { showsQueue.toggle() } }
                .foregroundStyle(showsQueue ? Theme.leaf : .white)
                .padding(.top, 20).padding(.trailing, 20)
        }
        #if os(macOS)
        .onExitCommand { music.showsNowPlaying = false }
        #elseif os(tvOS)
        .onExitCommand { music.showsNowPlaying = false }
        .onPlayPauseCommand { music.togglePause() }
        #endif
    }

    private func cover(_ size: CGSize) -> CGFloat {
        min(420, size.width * 0.7, size.height * 0.42)
    }
}

// MARK: - Queue

/// The queue: played tracks dimmed, the current one marked, then what comes next (drag to reorder).
struct QueueList: View {
    @ObservedObject private var music = MusicPlayer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hàng đợi").font(.title3.weight(.bold))
                Text("\(music.upcoming.count) bài tiếp theo").font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                if !music.upcoming.isEmpty {
                    Button("Xoá hàng đợi") { music.clearUpcoming() }
                        .font(.caption.weight(.semibold))
                        #if !os(tvOS)
                        .buttonStyle(.plain)
                        #endif
                        .foregroundStyle(Theme.leaf)
                }
            }
            List {
                ForEach(Array(music.queue.enumerated()), id: \.element.id) { position, item in
                    Button { music.jump(to: position) } label: {
                        QueueRow(item: item, isCurrent: position == music.index, played: position < music.index)
                    }
                    #if !os(tvOS)
                    .buttonStyle(.plain)
                    #endif
                    .listRowBackground(position == music.index ? Color.white.opacity(0.12) : Color.clear)
                    .contextMenu {
                        Button(role: .destructive) { music.remove(at: position) } label: {
                            Label("Xoá khỏi hàng đợi", systemImage: "minus.circle")
                        }
                        .disabled(position == music.index)
                    }
                }
                .onMove { music.move(from: $0, to: $1) }
                .onDelete { offsets in offsets.sorted(by: >).forEach { music.remove(at: $0) } }
            }
            .listStyle(.plain)
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
        }
    }
}

private struct QueueRow: View {
    let item: PlaybackItem
    let isCurrent: Bool
    let played: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(path: item.artworkPath, size: "w185", placeholderIcon: "music.note")
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill").font(.caption).padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(isCurrent ? .bold : .regular)).lineLimit(1)
                if let subtitle = item.subtitle { Text(subtitle).font(.caption).opacity(0.65).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .opacity(played ? 0.5 : 1)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Signal path

extension SignalPath.Grade {
    var color: Color {
        switch self {
        case .bitPerfect: return Color(red: 0.62, green: 0.45, blue: 1.0)
        case .highQuality: return Theme.leaf
        case .enhanced: return Color(red: 0.35, green: 0.62, blue: 1.0)
        case .lossy: return Color(red: 1.0, green: 0.78, blue: 0.25)
        case .unknown: return .gray
        }
    }
}

/// The coloured light next to the transport buttons; click for the whole path (as in Roon).
private struct SignalPathDot: View {
    @ObservedObject var engine: MPVPlayerEngine
    @State private var showsPath = false

    var body: some View {
        let path = SignalPath(engine: engine)
        Button { showsPath.toggle() } label: {
            Circle().fill(engine.audioOutput.isEmpty ? Color.gray : path.grade.color)
                .frame(width: 9, height: 9)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .help("Đường tín hiệu: \(path.grade.label)")
        #if !os(tvOS)
        .buttonStyle(.plain)
        .popover(isPresented: $showsPath) {
            SignalPathView(engine: engine).padding(18).frame(width: 340)
        }
        #endif
    }
}

/// "● Bit-perfect · FLAC · 96 kHz · 24-bit" under the title in Now Playing; tap for details.
private struct SignalPathBadge: View {
    @ObservedObject var engine: MPVPlayerEngine
    @State private var showsPath = false

    var body: some View {
        let path = SignalPath(engine: engine)
        Button { showsPath.toggle() } label: {
            HStack(spacing: 8) {
                Circle().fill(path.grade.color).frame(width: 8, height: 8)
                Text([path.grade.label, path.source].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(0.12), in: Capsule())
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        .popover(isPresented: $showsPath) {
            SignalPathView(engine: engine).padding(18).frame(width: 340)
        }
        #endif
        .opacity(engine.audioOutput.isEmpty ? 0 : 1)
    }
}

/// Source → processing → output, each step on its own line.
struct SignalPathView: View {
    @ObservedObject var engine: MPVPlayerEngine

    var body: some View {
        let path = SignalPath(engine: engine)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(path.grade.color).frame(width: 10, height: 10)
                Text("Đường tín hiệu: \(path.grade.label)").font(.headline)
            }
            step("Nguồn", path.source, icon: "waveform")
            if path.processing.isEmpty {
                step("Xử lý", "Không — giữ nguyên dữ liệu gốc", icon: "checkmark.seal")
            } else {
                ForEach(path.processing, id: \.self) { step("Xử lý", $0, icon: "slider.horizontal.3") }
            }
            step("Thiết bị", path.output, icon: "hifispeaker")
            Text(Self.explanation(path.grade)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func step(_ title: String, _ value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).fontWeight(.medium)
        }
        .font(.callout)
    }

    static func explanation(_ grade: SignalPath.Grade) -> String {
        switch grade {
        case .bitPerfect: return "Thiết bị nhận đúng từng mẫu của file, ở đúng tần số gốc."
        case .highQuality: return "Không mất dữ liệu nhưng có lấy mẫu lại hoặc chỉnh âm lượng số. Bật “Khớp tần số lấy mẫu” (Mac) hoặc để âm lượng 100 % để đạt bit-perfect."
        case .enhanced: return "Đang bật xử lý âm thanh (tăng thoại, ban đêm, cân bằng âm lượng)."
        case .lossy: return "File gốc đã nén mất dữ liệu (MP3, AAC, Opus…)."
        case .unknown: return "Đang mở bài tiếp theo."
        }
    }
}
