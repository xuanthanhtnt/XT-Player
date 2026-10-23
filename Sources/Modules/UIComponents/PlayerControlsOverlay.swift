import SwiftUI

/// Tabs of the player's settings panel (Infuse-style: it slides in from the right over the video).
enum PlayerPanel: String, Identifiable, CaseIterable {
    case audio, subtitles, video, chapters, info
    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: return "Âm thanh"
        case .subtitles: return "Phụ đề"
        case .video: return "Video"
        case .chapters: return "Chương"
        case .info: return "Thông tin"
        }
    }
}

/// Player chrome.
/// - macOS: Infuse's layout — a "Đóng" pill top-left and one floating bar at the bottom
///   (volume · transport · settings / mini player / full screen, then the scrubber).
/// - iPhone / iPad: centre transport over a bottom bar (touch).
/// - Apple TV: the bottom bar, driven by the focus engine.
struct PlayerControlsOverlay: View {
    @ObservedObject var engine: MPVPlayerEngine
    let title: String
    var subtitle: String?
    let resumedFrom: Double?
    var hasNext = false
    var hasPrevious = false
    var skipBack: Double = 10
    var skipForward: Double = 30
    @Binding var panel: PlayerPanel?
    var isFullScreen = false
    var isMini = false
    /// macOS: height of the title band above the controls (0 in full screen).
    var topInset: CGFloat = 0
    let onClose: () -> Void
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onToggleFullScreen: () -> Void = {}
    var onToggleMini: () -> Void = {}
    /// macOS: the pointer entered / left the control bar (the controls stay up while it is there).
    var onHoverControls: (Bool) -> Void = { _ in }
    let onInteraction: () -> Void

    /// Time shown while dragging the scrubber, and until the seek lands.
    @State private var scrubPosition: Double?
    @State private var isScrubbing = false
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        #if os(macOS)
        macBody
            .onChange(of: engine.position) { _, position in
                // Drop the scrub preview once playback has caught up with the seek.
                if !isScrubbing, let target = scrubPosition, abs(position - target) < 1.5 { scrubPosition = nil }
            }
        #else
        touchBody
        #endif
    }

    // MARK: - macOS (Infuse)

    #if os(macOS)
    private var macBody: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 560
            let barBottom: CGFloat = isFullScreen ? 50 : (isMini || compact ? 10 : 28)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        pill("xmark", text: "Đóng", help: "Đóng (Esc)", action: onClose)
                        if showStartOver {
                            pill("backward.end.fill", text: "Xem từ đầu", help: "Phát lại từ đầu") {
                                engine.seek(to: 0)
                                onInteraction()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, topInset + 8)

                    Spacer(minLength: 0)

                    controlBar(compact: compact)
                        .padding(.horizontal, 12)
                        .padding(.bottom, barBottom)
                }

                if let panel {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        panelCard(panel)
                            .frame(width: min(Self.panelWidth, max(240, geo.size.width - 24)))
                    }
                    .padding(.trailing, 12)
                    .padding(.top, topInset + 8)
                    .padding(.bottom, barBottom + Self.barHeight + 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.22), value: panel)
    }

    /// Infuse's floating bar: 600 pt wide, two rows.
    private func controlBar(compact: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                HStack(spacing: 0) {
                    if !compact {
                        PlayerSlider(value: volumeFraction, trackHeight: 3, onChange: { fraction in
                            engine.setVolume(fraction * 100)
                            onInteraction()
                        })
                        .frame(width: 80)
                        .help("Âm lượng — M: tắt / bật tiếng")
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        barButton(help: "Âm thanh, phụ đề, video, thông tin") {
                            panel = panel == nil ? .audio : nil
                        } label: {
                            Image(systemName: "gearshape.fill").font(.system(size: 16, weight: .medium))
                        }
                        barButton(help: isMini ? "Trở lại cửa sổ thường" : "Cửa sổ nổi — nhỏ, luôn ở trên") {
                            onToggleMini()
                        } label: {
                            Image(systemName: isMini ? "pip.exit" : "pip.enter").font(.system(size: 16, weight: .regular))
                        }
                        barButton(help: isFullScreen ? "Thoát toàn màn hình (F)" : "Toàn màn hình (F)") {
                            onToggleFullScreen()
                        } label: {
                            FullScreenGlyph(exit: isFullScreen)
                                .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                                .frame(width: 14, height: 13)
                        }
                    }
                    .padding(.trailing, 8)
                }
                .padding(.leading, 13)

                HStack(spacing: 0) {
                    let width: CGFloat = compact ? 48 : 55
                    if !compact {
                        transportButton("backward.end.fill", size: 14, width: width, help: previousHelp, action: goPrevious)
                    }
                    transportButton("gobackward", size: 20, weight: .medium, width: width, help: "Lùi \(Int(skipBack)) giây (←)") {
                        engine.seek(by: -skipBack)
                    }
                    transportButton(playPauseIcon, size: engine.state == .playing ? 21 : 23, width: width,
                                    help: "Phát / Dừng (Space)", action: togglePlayback)
                    transportButton("goforward", size: 20, weight: .medium, width: width, help: "Tới \(Int(skipForward)) giây (→)") {
                        engine.seek(by: skipForward)
                    }
                    if !compact {
                        transportButton("forward.end.fill", size: 14, width: width, help: nextHelp, enabled: canGoNext, action: goNext)
                    }
                }
            }
            .frame(height: 30)

            HStack(spacing: 0) {
                Text(TimeFormat.clock(scrubPosition ?? engine.position))
                    .frame(width: compact ? 54 : 62, alignment: .leading)
                PlayerSlider(
                    value: fraction(of: scrubPosition ?? engine.position),
                    buffered: fraction(of: engine.position + engine.bufferedSeconds),
                    marks: chapterMarks,
                    trackHeight: 4,
                    bubble: { at in
                        let time = at * engine.duration
                        return [engine.chapters.last { $0.time <= time }?.title, TimeFormat.clock(time)].compactMap { $0 }
                    },
                    bubbleLift: 50,
                    onChange: { at in
                        isScrubbing = true
                        scrubPosition = at * engine.duration
                        onInteraction()
                    },
                    onEnd: { at in commitScrub(at * engine.duration) }
                )
                .disabled(engine.duration <= 0)
                Text("-" + TimeFormat.clock(max(0, engine.duration - (scrubPosition ?? engine.position))))
                    .frame(width: compact ? 62 : 64, alignment: .trailing)
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .frame(height: 20)
            .padding(.leading, 13)
            .padding(.trailing, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: 600)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .onHover(perform: onHoverControls)
    }

    private func pill(_ icon: String, text: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .bold))
                Text(text).font(.system(size: 14, weight: .medium))
            }
            .padding(.leading, 11)
            .padding(.trailing, 13)
            .frame(height: 32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PlayerIconButtonStyle())
        .help(help)
    }

    private func transportButton(_ icon: String, size: CGFloat, weight: Font.Weight = .semibold, width: CGFloat,
                                 help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: weight))
                .frame(width: width, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerIconButtonStyle())
        .disabled(!enabled)
        .help(help)
    }

    private func barButton<Label: View>(help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            label()
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerIconButtonStyle())
        .help(help)
    }

    private var volumeFraction: Double {
        engine.isMuted ? 0 : min(1, max(0, engine.volume / 100))
    }

    private func fraction(of seconds: Double) -> Double {
        engine.duration > 0 ? min(1, max(0, seconds / engine.duration)) : 0
    }

    private func commitScrub(_ target: Double) {
        isScrubbing = false
        scrubPosition = target
        engine.seek(to: target)
        onInteraction()
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, !isScrubbing { scrubPosition = nil }
        }
    }

    // ⏮ / ⏭ follow chapters when the file has them, then the queue (like Infuse).

    private var currentChapterStart: Double? {
        engine.chapters.first { $0.id == engine.currentChapter }?.time
    }

    private func goPrevious() {
        if hasPrevious, engine.position < 5 {
            onPrevious()
        } else if let start = currentChapterStart, engine.currentChapter > 0, engine.position - start < 3 {
            engine.selectChapter(engine.currentChapter - 1)
        } else {
            engine.seek(to: currentChapterStart ?? 0)
        }
    }

    private var hasNextChapter: Bool {
        engine.currentChapter >= 0 && engine.currentChapter < engine.chapters.count - 1
    }

    private var canGoNext: Bool { hasNextChapter || hasNext }

    private func goNext() {
        if hasNextChapter {
            engine.selectChapter(engine.currentChapter + 1)
        } else if hasNext {
            onNext()
        }
    }

    private var previousHelp: String {
        engine.chapters.isEmpty ? (hasPrevious ? "Về đầu / tập trước" : "Về đầu") : "Chương trước"
    }

    private var nextHelp: String {
        hasNextChapter ? "Chương tiếp" : (hasNext ? "Tập tiếp (N)" : "Không có mục tiếp theo")
    }

    private static let barHeight: CGFloat = 80
    #endif

    // MARK: - iPhone / iPad / Apple TV

    #if !os(macOS)
    private var touchBody: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 240)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                #if os(iOS)
                centerTransport
                Spacer(minLength: 0)
                #endif
                bottomPanel
            }
            .padding(.horizontal, Self.edge)
            .padding(.vertical, Self.edge * 0.6)

            if let panel {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    panelCard(panel).frame(width: Self.panelWidth)
                }
                .padding(.horizontal, Self.edge)
                .padding(.top, Self.edge * 0.6 + 52)
                .padding(.bottom, Self.edge * 0.6 + Self.bottomPanelHeight)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: panel)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            roundButton("xmark", help: "Đóng", action: onClose)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if showStartOver {
                Button {
                    engine.seek(to: 0)
                    onInteraction()
                } label: {
                    Label("Xem từ đầu", systemImage: "backward.end.fill")
                        .font(.callout.weight(.semibold))
                }
                #if !os(tvOS)
                .buttonStyle(.bordered)
                #endif
            }
        }
        .foregroundStyle(.white)
    }

    #if os(iOS)
    private var centerTransport: some View {
        HStack(spacing: 44) {
            if hasPrevious { transportButton("backward.end.fill", size: 24, help: "Trước") { onPrevious() } }
            transportButton(Self.skipIcon("gobackward", skipBack), size: 30, help: "Lùi") { engine.seek(by: -skipBack) }
            transportButton(playPauseIcon, size: 48, help: "Phát / Dừng") { togglePlayback() }
            transportButton(Self.skipIcon("goforward", skipForward), size: 30, help: "Tới") { engine.seek(by: skipForward) }
            if hasNext { transportButton("forward.end.fill", size: 24, help: "Tiếp") { onNext() } }
        }
    }

    private func transportButton(_ icon: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 1.7, height: size * 1.7)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
    #endif

    private var bottomPanel: some View {
        VStack(spacing: Self.rowSpacing) {
            timeline
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    #if os(tvOS)
                    if hasPrevious { tvButton("backward.end.fill") { onPrevious() } }
                    tvButton(Self.skipIcon("gobackward", skipBack)) { engine.seek(by: -skipBack) }
                    tvButton(playPauseIcon) { togglePlayback() }
                    tvButton(Self.skipIcon("goforward", skipForward)) { engine.seek(by: skipForward) }
                    if hasNext { tvButton("forward.end.fill") { onNext() } }
                    #else
                    ViewThatFits(in: .horizontal) {
                        SignalBadges(engine: engine, compact: false)
                        SignalBadges(engine: engine, compact: true)
                        Color.clear.frame(width: 1, height: 1)
                    }
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if !engine.chapters.isEmpty { panelButton(.chapters, icon: "list.bullet.rectangle") }
                    panelButton(.audio, icon: "speaker.wave.2.fill")
                    panelButton(.subtitles, icon: "captions.bubble.fill")
                    panelButton(.video, icon: "slider.horizontal.3")
                    panelButton(.info, icon: "info.circle")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Self.panelPadding)
        .padding(.vertical, Self.panelPadding * 0.75)
        #if os(iOS)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 1100)
        #endif
        .foregroundStyle(.white)
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            Text(TimeFormat.clock(scrubPosition ?? engine.position))
                .frame(minWidth: Self.timeWidth, alignment: .leading)
            #if os(tvOS)
            ProgressTrack(progress: progress, buffered: bufferedProgress, marks: chapterMarks)
                .frame(height: 10)
            #else
            ScrubBar(position: engine.position, duration: engine.duration,
                     bufferedUntil: engine.position + engine.bufferedSeconds, marks: chapterMarks,
                     chapters: engine.chapters, scrubPosition: $scrubPosition,
                     onCommit: { engine.seek(to: $0) }, onInteraction: onInteraction)
            #endif
            Text("-" + TimeFormat.clock(max(0, engine.duration - (scrubPosition ?? engine.position))))
                .frame(minWidth: Self.timeWidth, alignment: .trailing)
        }
        .font(.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
    }

    private func panelButton(_ target: PlayerPanel, icon: String) -> some View {
        Button {
            panel = panel == target ? nil : target
            onInteraction()
        } label: {
            Label(target.title, systemImage: icon)
                .font(.callout.weight(.semibold))
                #if !os(tvOS)
                .labelStyle(.iconOnly)
                .foregroundStyle(panel == target ? Theme.leaf : .white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(panel == target ? 0.16 : 0.001)))
                .contentShape(Circle())
                #endif
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
    }

    private func roundButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                #if !os(tvOS)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
                .contentShape(Circle())
                #endif
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        .help(help)
        #endif
    }

    #if os(tvOS)
    private func tvButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Image(systemName: icon).font(.title3.weight(.semibold))
        }
    }
    #endif

    private var progress: Double {
        engine.duration > 0 ? min(1, engine.position / engine.duration) : 0
    }

    private var bufferedProgress: Double {
        engine.duration > 0 ? min(1, (engine.position + engine.bufferedSeconds) / engine.duration) : 0
    }

    /// SF Symbols only ship gobackward/goforward for a few intervals.
    private static func skipIcon(_ base: String, _ seconds: Double) -> String {
        let s = Int(seconds)
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(s) ? "\(base).\(s)" : base
    }

    #if os(tvOS)
    private static let edge: CGFloat = 80
    private static let panelPadding: CGFloat = 0
    private static let rowSpacing: CGFloat = 22
    private static let timeWidth: CGFloat = 110
    private static let bottomPanelHeight: CGFloat = 170
    #else
    private static let edge: CGFloat = 20
    private static let panelPadding: CGFloat = 18
    private static let rowSpacing: CGFloat = 8
    private static let timeWidth: CGFloat = 52
    private static let bottomPanelHeight: CGFloat = 110
    #endif
    #endif

    // MARK: - Settings panel (all platforms)

    private var availablePanels: [PlayerPanel] {
        PlayerPanel.allCases.filter { $0 != .chapters || !engine.chapters.isEmpty }
    }

    private func panelCard(_ current: PlayerPanel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(availablePanels) { tab in
                            Button {
                                panel = tab
                                onInteraction()
                            } label: {
                                Text(tab.title)
                                    .font(.callout.weight(.semibold))
                                    #if !os(tvOS)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(tab == current ? Color.white : Color.white.opacity(0.6))
                                    .background(Capsule().fill(Color.white.opacity(tab == current ? 0.16 : 0.001)))
                                    .contentShape(Capsule())
                                    #endif
                            }
                            #if !os(tvOS)
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                    #if os(tvOS)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 8)
                    #endif
                }
                Button {
                    panel = nil
                    onInteraction()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                #if !os(tvOS)
                .buttonStyle(.plain)
                .help("Đóng bảng")
                #endif
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                Group {
                    switch current {
                    case .audio: AudioPanel(engine: engine, onInteraction: onInteraction)
                    case .subtitles: SubtitlePanel(engine: engine, onInteraction: onInteraction)
                    case .video: VideoPanel(engine: engine, onInteraction: onInteraction)
                    case .chapters: ChaptersPanel(engine: engine, onInteraction: onInteraction)
                    case .info: InfoPanel(engine: engine)
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxHeight: .infinity)
        #if os(tvOS)
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        #else
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .environment(\.colorScheme, .dark)
        #endif
        .foregroundStyle(.white)
    }

    // MARK: - Shared helpers

    private var showStartOver: Bool {
        guard let resumedFrom else { return false }
        return engine.position < resumedFrom + 30 && engine.position > 1
    }

    private var playPauseIcon: String {
        switch engine.state {
        case .playing: return "pause.fill"
        case .ended: return "arrow.counterclockwise"
        default: return "play.fill"
        }
    }

    private func togglePlayback() {
        if engine.state == .ended {
            engine.seek(to: 0)
            engine.play()
        } else {
            engine.togglePause()
        }
    }

    private var chapterMarks: [Double] {
        guard engine.duration > 0 else { return [] }
        return engine.chapters.map { $0.time / engine.duration }.filter { $0 > 0.005 && $0 < 0.995 }
    }

    static let playbackSpeeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func speedText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    #if os(tvOS)
    private static let panelWidth: CGFloat = 720
    #else
    private static let panelWidth: CGFloat = 370
    #endif
}

// MARK: - macOS controls

#if os(macOS)
/// White icons that dim when pressed or disabled.
struct PlayerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .opacity(!isEnabled ? 0.35 : (configuration.isPressed ? 0.55 : (hovering ? 1 : 0.94)))
                .scaleEffect(configuration.isPressed ? 0.93 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Infuse's slider: a thin track (white up to the knob) and a large white knob. Used for volume and
/// for the scrubber, which adds the buffered range, chapter ticks and a time bubble while hovering.
struct PlayerSlider: View {
    /// 0…1
    let value: Double
    var buffered: Double = 0
    var marks: [Double] = []
    var trackHeight: CGFloat = 3
    var knobSize: CGFloat = 20
    /// Lines of the bubble shown above the pointer while hovering or dragging; nil = no bubble.
    var bubble: ((Double) -> [String])?
    var bubbleLift: CGFloat = 40
    let onChange: (Double) -> Void
    var onEnd: (Double) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var hover: Double?
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let travel = max(1, width - knobSize)
            let shown = min(1, max(0, dragging ?? value))
            let knobX = knobSize / 2 + travel * shown
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.38))
                    .frame(height: trackHeight)
                if buffered > shown {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: knobSize / 2 + travel * min(1, buffered), height: trackHeight)
                }
                Capsule()
                    .fill(Color.white)
                    .frame(width: knobX, height: trackHeight)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 2, height: trackHeight)
                        .offset(x: knobSize / 2 + travel * mark - 1)
                }
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobX - knobSize / 2)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let at = fraction(drag.location.x, travel: travel)
                        dragging = at
                        onChange(at)
                    }
                    .onEnded { drag in
                        let at = fraction(drag.location.x, travel: travel)
                        dragging = nil
                        onEnd(at)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hover = fraction(point.x, travel: travel)
                case .ended: hover = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if isEnabled, let bubble, let at = dragging ?? hover {
                    let lines = bubble(at)
                    VStack(spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(index < lines.count - 1 ? Font.caption2 : Font.caption.weight(.semibold).monospacedDigit())
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize()
                    .position(x: min(max(knobSize / 2 + travel * at, 50), max(50, width - 50)), y: geo.size.height / 2 - bubbleLift)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: knobSize + 2)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func fraction(_ x: CGFloat, travel: CGFloat) -> Double {
        Double(min(1, max(0, (x - knobSize / 2) / travel)))
    }
}

/// Infuse's full-screen glyph: four corner brackets, pointing out (enter) or in (exit).
struct FullScreenGlyph: Shape {
    var exit: Bool

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        func bracket(_ a: CGPoint, _ corner: CGPoint, _ b: CGPoint, into path: inout Path) {
            path.move(to: a)
            path.addLine(to: corner)
            path.addLine(to: b)
        }
        var path = Path()
        if exit {
            let i: CGFloat = 0.38
            bracket(point(i, 0), point(i, i), point(0, i), into: &path)
            bracket(point(1 - i, 0), point(1 - i, i), point(1, i), into: &path)
            bracket(point(0, 1 - i), point(i, 1 - i), point(i, 1), into: &path)
            bracket(point(1, 1 - i), point(1 - i, 1 - i), point(1 - i, 1), into: &path)
        } else {
            let a: CGFloat = 0.36
            bracket(point(0, a), point(0, 0), point(a, 0), into: &path)
            bracket(point(1 - a, 0), point(1, 0), point(1, a), into: &path)
            bracket(point(1, 1 - a), point(1, 1), point(1 - a, 1), into: &path)
            bracket(point(a, 1), point(0, 1), point(0, 1 - a), into: &path)
        }
        return path
    }
}
#endif

// MARK: - Scrub bar (iPhone / iPad)

#if os(iOS)
/// Thin scrubber: grows while dragging, shows buffered range, chapter ticks and a time bubble.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    let bufferedUntil: Double
    let marks: [Double]
    let chapters: [Chapter]
    @Binding var scrubPosition: Double?
    let onCommit: (Double) -> Void
    let onInteraction: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let shown = scrubPosition ?? position
            let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
            let buffered = duration > 0 ? min(1, max(0, bufferedUntil / duration)) : 0
            let active = scrubPosition != nil

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Color.white.opacity(0.32)).frame(width: width * buffered)
                Capsule().fill(Theme.brandGradient).frame(width: max(6, width * fraction))
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: 2).offset(x: width * mark - 1)
                }
            }
            .frame(height: active ? 8 : 5)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .frame(width: active ? 16 : 0, height: active ? 16 : 0)
                    .offset(x: width * fraction - (active ? 8 : 0))
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if let scrubPosition {
                    let x = CGFloat(scrubPosition / max(duration, 1)) * width
                    VStack(spacing: 2) {
                        if let chapter = chapters.last(where: { $0.time <= scrubPosition })?.title {
                            Text(chapter).font(.caption2).lineLimit(1)
                        }
                        Text(TimeFormat.clock(scrubPosition)).font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize()
                    .position(x: min(max(x, 40), width - 40), y: -18)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubPosition = duration * Double(min(1, max(0, value.location.x / width)))
                        onInteraction()
                    }
                    .onEnded { value in
                        let target = duration * Double(min(1, max(0, value.location.x / width)))
                        onCommit(target)
                        scrubPosition = nil
                        onInteraction()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 26)
    }
}
#endif

#if os(tvOS)
private struct ProgressTrack: View {
    let progress: Double
    let buffered: Double
    var marks: [Double] = []

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Color.white.opacity(0.28)).frame(width: geo.size.width * buffered)
                Capsule().fill(Theme.brandGradient).frame(width: max(10, geo.size.width * progress))
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: 3).offset(x: geo.size.width * mark)
                }
            }
        }
    }
}
#endif

// MARK: - Badges

/// Resolution · dynamic range · frame rate · codec · decoder · audio.
struct SignalBadges: View {
    @ObservedObject var engine: MPVPlayerEngine
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            let video = engine.video
            if !video.resolutionLabel.isEmpty { TagChip(text: video.resolutionLabel) }
            if !video.gamma.isEmpty {
                TagChip(text: video.dynamicRangeLabel(hdrOutput: engine.hdrOutputActive), highlighted: video.dynamicRange != .sdr)
            }
            if !compact {
                if video.fps > 1 { TagChip(text: video.fpsLabel) }
                if !engine.videoCodec.isEmpty { TagChip(text: engine.videoCodec) }
            }
            if !engine.audio.codec.isEmpty {
                TagChip(text: engine.audio.codec + (engine.audio.channels > 0 ? " " + MediaTrack.channelLayout(engine.audio.channels) : ""))
            }
        }
        .fixedSize()
    }
}

extension VideoSignal {
    var fpsLabel: String {
        abs(fps - fps.rounded()) < 0.01 ? "\(Int(fps.rounded())) fps" : String(format: "%.3f fps", fps)
    }

    func dynamicRangeLabel(hdrOutput: Bool) -> String {
        var text = dynamicRange.rawValue
        if dynamicRange == .dolbyVision, dolbyVisionProfile > 0 { text += " P\(dolbyVisionProfile)" }
        if dynamicRange != .sdr, !hdrOutput { text += " → SDR" }
        return text
    }
}

// MARK: - Panel building blocks

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            content()
        }
    }
}

/// A selectable row with a check mark (track, frame mode, speed, chapter…).
struct PanelChoice: View {
    let text: String
    var detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Theme.leaf)
                    .opacity(selected ? 1 : 0)
                Text(text).font(.callout).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(selected ? Color.white.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
    }
}

/// − value + ↺ row for offsets and sizes.
struct PanelStepper: View {
    let title: String
    let value: String
    let minus: () -> Void
    let plus: () -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.callout)
            Spacer(minLength: 0)
            stepButton("minus", minus)
            Text(value).font(.callout.monospacedDigit()).frame(minWidth: 72)
            stepButton("plus", plus)
            stepButton("arrow.uturn.backward", reset)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout.weight(.bold))
                #if !os(tvOS)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
                #endif
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - Panels

struct AudioPanel: View {
    @ObservedObject var engine: MPVPlayerEngine
    let onInteraction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelSection(title: "Track âm thanh") {
                if engine.audioTracks.isEmpty {
                    Text("Không có track âm thanh").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                ForEach(engine.audioTracks) { track in
                    PanelChoice(text: track.label, selected: track.isSelected) {
                        engine.selectAudioTrack(track.id)
                        onInteraction()
                    }
                }
            }
            #if os(macOS)
            if engine.audioDevices.count > 1 {
                PanelSection(title: "Thiết bị phát") {
                    ForEach(engine.audioDevices) { device in
                        PanelChoice(text: device.description, selected: device.id == engine.audioDevice) {
                            engine.selectAudioDevice(device.id)
                            onInteraction()
                        }
                    }
                }
            }
            #endif
            PanelSection(title: "Night Mode") {
                PanelChoice(text: "Nén dải động — nghe rõ thoại khi để nhỏ", detail: engine.nightMode ? "Bật" : "Tắt",
                            selected: engine.nightMode) {
                    engine.setNightMode(!engine.nightMode)
                    onInteraction()
                }
            }
            PanelSection(title: "Đồng bộ") {
                PanelStepper(title: "Lệch tiếng", value: String(format: "%+.0f ms", engine.audioDelay * 1000),
                             minus: { engine.adjustAudioDelay(by: -0.05); onInteraction() },
                             plus: { engine.adjustAudioDelay(by: 0.05); onInteraction() },
                             reset: { engine.resetAudioDelay(); onInteraction() })
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .onAppear { engine.refreshAudioDevices() }
    }
}

struct SubtitlePanel: View {
    @ObservedObject var engine: MPVPlayerEngine
    let onInteraction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelSection(title: "Track phụ đề") {
                PanelChoice(text: "Tắt", selected: engine.subtitleTracks.allSatisfy { !$0.isSelected }) {
                    engine.selectSubtitleTrack(nil)
                    onInteraction()
                }
                ForEach(engine.subtitleTracks) { track in
                    PanelChoice(text: track.label, selected: track.isSelected) {
                        engine.selectSubtitleTrack(track.id)
                        onInteraction()
                    }
                }
            }
            PanelSection(title: "Đồng bộ") {
                PanelStepper(title: "Lệch phụ đề", value: String(format: "%+.1f s", engine.subtitleDelay),
                             minus: { engine.adjustSubtitleDelay(by: -0.1); onInteraction() },
                             plus: { engine.adjustSubtitleDelay(by: 0.1); onInteraction() },
                             reset: { engine.resetSubtitleDelay(); onInteraction() })
                #if !os(tvOS)
                Text("Phím tắt: Z / X lệch phụ đề ±0,1 s").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                #endif
            }
            PanelSection(title: "Cỡ chữ") {
                PanelStepper(title: "Cỡ phụ đề", value: "\(Int((engine.subtitleScale * 100).rounded()))%",
                             minus: { engine.adjustSubtitleScale(by: -0.1); onInteraction() },
                             plus: { engine.adjustSubtitleScale(by: 0.1); onInteraction() },
                             reset: { engine.adjustSubtitleScale(by: 1 - engine.subtitleScale); onInteraction() })
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
    }
}

struct VideoPanel: View {
    @ObservedObject var engine: MPVPlayerEngine
    let onInteraction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelSection(title: "Khung hình") {
                ForEach(VideoFit.allCases) { fit in
                    PanelChoice(text: fit.label, selected: engine.videoFit == fit) {
                        engine.setVideoFit(fit)
                        onInteraction()
                    }
                }
            }
            PanelSection(title: "Tốc độ phát") {
                ForEach(PlayerControlsOverlay.playbackSpeeds, id: \.self) { value in
                    PanelChoice(text: PlayerControlsOverlay.speedText(value), selected: abs(engine.speed - value) < 0.01) {
                        engine.setSpeed(value)
                        onInteraction()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
    }
}

struct ChaptersPanel: View {
    @ObservedObject var engine: MPVPlayerEngine
    let onInteraction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(engine.chapters) { chapter in
                PanelChoice(text: chapter.title, detail: TimeFormat.clock(chapter.time), selected: chapter.id == engine.currentChapter) {
                    engine.selectChapter(chapter.id)
                    onInteraction()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
    }
}

/// Technical details of what is playing, and the tail of the libmpv log (copyable for bug reports).
struct InfoPanel: View {
    @ObservedObject var engine: MPVPlayerEngine
    @State private var logLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                SignalBadges(engine: engine, compact: false)
                SignalBadges(engine: engine, compact: true)
            }
            section("Video") {
                row("Định dạng", engine.videoCodec)
                if engine.video.width > 0 { row("Độ phân giải", "\(engine.video.width) × \(engine.video.height)") }
                if engine.video.fps > 1 { row("Khung hình", engine.video.fpsLabel) }
                if !engine.video.gamma.isEmpty {
                    row("Dải động", engine.video.dynamicRangeLabel(hdrOutput: engine.hdrOutputActive))
                    row("Màu", [engine.video.primaries, engine.video.gamma, engine.video.colorMatrix].filter { !$0.isEmpty }.joined(separator: " / "))
                }
                row("Giải mã", engine.hardwareDecoder.isEmpty || engine.hardwareDecoder == "no" ? "Phần mềm (CPU)" : "Phần cứng · \(engine.hardwareDecoder)")
                if engine.videoBitrate > 0 { row("Bitrate", Self.bitrate(engine.videoBitrate)) }
            }
            section("Âm thanh") {
                row("Định dạng", engine.audio.codec)
                if engine.audio.channels > 0 { row("Kênh", MediaTrack.channelLayout(engine.audio.channels)) }
                if engine.audio.sampleRate > 0 { row("Tần số", String(format: "%.1f kHz", Double(engine.audio.sampleRate) / 1000)) }
                if engine.audio.outputChannels > 0 { row("Kênh ra", MediaTrack.channelLayout(engine.audio.outputChannels)) }
                row("Đầu ra", engine.audioOutput.isEmpty ? "Chưa mở — không có tiếng" : engine.audioOutput,
                    warning: engine.audioOutput.isEmpty && !engine.audioTracks.isEmpty)
                row("Âm lượng", engine.isMuted ? "Đang tắt tiếng" : "\(Int(engine.volume))%", warning: engine.isMuted)
                if engine.audioBitrate > 0 { row("Bitrate", Self.bitrate(engine.audioBitrate)) }
            }
            section("Bộ đệm") {
                row("Đã nạp trước", "\(Int(engine.bufferedSeconds)) s")
            }
            section("Nhật ký libmpv") {
                LogLines(lines: Array(logLines.suffix(60)))
                LogActions(lines: logLines, onRefresh: refresh)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() { logLines = MPVLogBuffer.shared.snapshot() }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, warning: Bool = false) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 12)
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(warning ? Theme.danger : .white)
            }
            .font(.callout)
        }
    }

    static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000 ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000) : String(format: "%.0f kbps", bitsPerSecond / 1000)
    }
}
