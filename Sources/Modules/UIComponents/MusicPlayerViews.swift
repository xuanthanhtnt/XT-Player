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
            #if os(tvOS)
            TVNowPlaying(engine: engine, item: current)
            #else
            NowPlayingContent(engine: engine, item: current)
            #endif
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
            // A labelled button (and Esc) so the way back to the library is obvious.
            Button { music.showsNowPlaying = false } label: {
                Label("Thu nhỏ", systemImage: "chevron.down")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .contentShape(Capsule())
            }
            #if !os(tvOS)
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Về thư viện (Esc)")
            #endif
            .padding(.top, 16).padding(.leading, 20)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                AudioOptionsMenu(engine: engine)
                MusicButton("list.bullet", size: 18) { withAnimation(.easeInOut(duration: 0.25)) { showsQueue.toggle() } }
                    .foregroundStyle(showsQueue ? Theme.leaf : .white)
            }
            .padding(.top, 16).padding(.trailing, 20)
        }
        #if os(iOS)
        // A full-screen cover cannot be swiped away on its own: pull down to go back, as in Music.
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.height > 120, abs(value.translation.width) < value.translation.height {
                music.showsNowPlaying = false
            }
        })
        #elseif os(tvOS)
        .onExitCommand { music.showsNowPlaying = false }
        .onPlayPauseCommand { music.togglePause() }
        #endif
    }

    private func cover(_ size: CGSize) -> CGFloat {
        min(420, size.width * 0.7, size.height * 0.42)
    }
}

#if os(tvOS)
/// Apple TV Now Playing, made for the room: the cover large on a slowly drifting blur of itself, the title big
/// beside it, glass buttons that grow under the focus, and the queue sliding in from the right. Track changes
/// cross-fade instead of jumping.
private struct TVNowPlaying: View {
    @ObservedObject var engine: MPVPlayerEngine
    @ObservedObject private var music = MusicPlayer.shared
    let item: PlaybackItem
    @State private var showsQueue = false
    @State private var drift = false
    @FocusState private var focus: Control?

    enum Control: Hashable { case shuffle, previous, playPause, next, repeatMode, queue }

    var body: some View {
        ZStack {
            Theme.background
            backdrop
            HStack(alignment: .center, spacing: showsQueue ? 54 : 96) {
                cover
                details
                if showsQueue {
                    QueueList()
                        .padding(28)
                        .frame(width: 600)
                        .frame(maxHeight: 820)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                        .focusSection()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, showsQueue ? 90 : 130)
            .padding(.vertical, 90)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .xSmall)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: showsQueue)
        .animation(.easeInOut(duration: 0.6), value: item.id)
        .defaultFocus($focus, .playPause)
        .onAppear { drift = true }
        .onExitCommand {
            if showsQueue { showsQueue = false; focus = .queue } else { music.showsNowPlaying = false }
        }
        .onPlayPauseCommand { music.togglePause() }
    }

    /// The cover, many times its size and blurred, drifting and turning slowly: the screen never sits still.
    private var backdrop: some View {
        // A 64 px copy stretched over the screen is soft already; a light blur finishes it (a 110 pt blur of the
        // full picture left the Apple TV showing nothing at all).
        ArtworkImage(path: item.artworkPath, size: "blur", placeholderIcon: "music.note")
            .scaleEffect(drift ? 1.5 : 1.2)
            .rotationEffect(.degrees(drift ? 6 : -6))
            .blur(radius: 40)
            .saturation(1.4)
            .animation(.easeInOut(duration: 28).repeatForever(autoreverses: true), value: drift)
            .overlay(
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.45), .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
            )
            .id(item.artworkPath ?? item.id.uuidString)
            .transition(.opacity)
    }

    private var cover: some View {
        let side: CGFloat = showsQueue ? 380 : 560
        return ArtworkImage(path: item.artworkPath, size: "w780", placeholderIcon: "music.note")
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.55), radius: 60, y: 30)
            // Breathes with playback, as in Music: full size while playing, set back when paused.
            .scaleEffect(engine.state == .playing ? 1 : 0.9)
            .animation(.spring(response: 0.55, dampingFraction: 0.72), value: engine.state == .playing)
            .id(item.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94)), removal: .opacity))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text(music.queue.count > 1 ? "ĐANG PHÁT · BÀI \(music.index + 1)/\(music.queue.count)" : "ĐANG PHÁT")
                .font(.caption.weight(.heavy))
                .tracking(3)
                .foregroundStyle(Theme.leaf)
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title)
                    .font(.system(size: showsQueue ? 40 : 52, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                }
            }
            .id(item.id)
            .transition(.opacity.combined(with: .offset(y: 12)))
            SignalPathBadge(engine: engine).fixedSize()
            TVProgress(engine: engine).padding(.top, 8)
            HStack(spacing: 34) {
                TVRoundButton(icon: "backward.fill", size: 80) { music.previous() }
                    .focused($focus, equals: .previous)
                TVRoundButton(icon: engine.state == .playing ? "pause.fill" : "play.fill", size: 104, prominent: true) { music.togglePause() }
                    .focused($focus, equals: .playPause)
                TVRoundButton(icon: "forward.fill", size: 80) { music.next() }
                    .focused($focus, equals: .next)
            }
            .padding(.top, 6)
            HStack(spacing: 22) {
                TVRoundButton(icon: "shuffle", size: 60, active: music.isShuffled) { music.toggleShuffle() }
                    .focused($focus, equals: .shuffle)
                TVRoundButton(icon: music.repeatMode == .one ? "repeat.1" : "repeat", size: 60, active: music.repeatMode != .off) { music.cycleRepeat() }
                    .focused($focus, equals: .repeatMode)
                TVRoundButton(icon: "list.bullet", size: 60, active: showsQueue) { showsQueue.toggle() }
                    .focused($focus, equals: .queue)
                AudioOptionsMenu(engine: engine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

/// Thick progress line with the times under it; it glides between position updates.
private struct TVProgress: View {
    @ObservedObject var engine: MPVPlayerEngine

    var body: some View {
        let fraction = engine.duration > 0 ? min(1, max(0, engine.position / engine.duration)) : 0
        VStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.leaf, Theme.leaf.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(12, geo.size.width * fraction))
                        .animation(.linear(duration: 0.5), value: fraction)
                }
            }
            .frame(height: 12)
            HStack {
                Text(TimeFormat.clock(engine.position))
                Spacer()
                Text("-" + TimeFormat.clock(max(0, engine.duration - engine.position)))
            }
            .font(.callout.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: 720)
    }
}

/// Round glass button: grows and turns white under the focus, like the system's own.
private struct TVRoundButton: View {
    let icon: String
    let size: CGFloat
    var prominent = false
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
        }
        .buttonStyle(TVRoundStyle(prominent: prominent, active: active))
    }
}

private struct TVRoundStyle: ButtonStyle {
    let prominent: Bool
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, prominent: prominent, active: active)
    }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let active: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : active ? Theme.leaf : Color.white)
                .background {
                    Circle()
                        .fill(isFocused ? AnyShapeStyle(Color.white) : prominent ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(.ultraThinMaterial))
                }
                .overlay(Circle().strokeBorder(.white.opacity(isFocused ? 0 : 0.12)))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 22, y: 12)
                .scaleEffect(configuration.isPressed ? 0.94 : isFocused ? 1.16 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
#endif

/// Sound processing for what is playing (the same switches as Settings ▸ Âm thanh), next to the queue button.
private struct AudioOptionsMenu: View {
    @ObservedObject var engine: MPVPlayerEngine

    var body: some View {
        Menu {
            Toggle("Tăng thoại", isOn: Binding(get: { engine.dialogBoost }, set: { engine.setDialogBoost($0) }))
            Toggle("Chế độ ban đêm", isOn: Binding(get: { engine.nightMode }, set: { engine.setNightMode($0) }))
            Toggle("Cân bằng âm lượng (ReplayGain)", isOn: Binding(get: { engine.volumeLeveling }, set: { engine.setVolumeLeveling($0) }))
            #if os(macOS)
            Toggle("Khớp tần số lấy mẫu với thiết bị", isOn: Binding(get: { engine.matchSampleRate }, set: { engine.setMatchSampleRate($0) }))
            #endif
        } label: {
            #if os(tvOS)
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 22, weight: .bold))
                .frame(width: 60, height: 60)
            #else
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
            #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        #elseif os(tvOS)
        .menuStyle(.button)
        .buttonStyle(TVRoundStyle(prominent: false, active: engine.dialogBoost || engine.nightMode))
        #endif
        .help("Xử lý âm thanh")
    }
}

// MARK: - Queue

/// The queue: played tracks dimmed, the current one marked, then what comes next (drag to reorder).
struct QueueList: View {
    @ObservedObject private var music = MusicPlayer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hàng đợi").font(.title3.weight(.bold)).lineLimit(1).fixedSize()
                #if !os(tvOS)
                Text("\(music.upcoming.count) bài tiếp theo").font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                #endif
                Spacer()
                if !music.upcoming.isEmpty {
                    Button("Xoá hàng đợi") { music.clearUpcoming() }
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
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
