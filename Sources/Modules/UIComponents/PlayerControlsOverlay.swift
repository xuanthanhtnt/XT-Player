import SwiftUI

/// Side panels of the player (Infuse-style: they slide in from the right over the video).
enum PlayerPanel: String, Identifiable {
    case tracks, info
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracks: return "Âm thanh & Phụ đề"
        case .info: return "Thông tin phát"
        }
    }
}

/// Floating transport, signal info, track & info panels. Works with touch (iOS/iPadOS),
/// pointer + keyboard (macOS) and the Siri Remote focus engine (tvOS).
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
    let onClose: () -> Void
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onToggleFullScreen: () -> Void = {}
    let onInteraction: () -> Void

    @State private var scrubPosition: Double?

    var body: some View {
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
                sidePanel(panel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: panel)
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            roundButton("xmark", help: "Đóng (Esc)", action: onClose)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if let resumedFrom, engine.position < resumedFrom + 30, engine.position > 1 {
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
            #if os(macOS)
            roundButton(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        help: isFullScreen ? "Thoát toàn màn hình (F)" : "Toàn màn hình (F)",
                        action: onToggleFullScreen)
            #endif
        }
        .foregroundStyle(.white)
    }

    // MARK: Center (iPhone / iPad)

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
    #endif

    #if !os(tvOS)
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

    // MARK: Bottom

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

                #if os(macOS)
                HStack(spacing: 6) {
                    if hasPrevious { transportButton("backward.end.fill", size: 16, help: "Tập trước") { onPrevious() } }
                    transportButton(Self.skipIcon("gobackward", skipBack), size: 19, help: "Lùi \(Int(skipBack))s (←)") { engine.seek(by: -skipBack) }
                    transportButton(playPauseIcon, size: 26, help: "Phát / Dừng (Space)") { togglePlayback() }
                    transportButton(Self.skipIcon("goforward", skipForward), size: 19, help: "Tới \(Int(skipForward))s (→)") { engine.seek(by: skipForward) }
                    if hasNext { transportButton("forward.end.fill", size: 16, help: "Tập tiếp (N)") { onNext() } }
                }
                .fixedSize()
                #endif

                HStack(spacing: 8) {
                    #if os(macOS)
                    volumeControl
                    #endif
                    if !engine.chapters.isEmpty { chapterMenu }
                    panelButton(.tracks, icon: "captions.bubble.fill")
                    optionsMenu
                    nightModeButton
                    panelButton(.info, icon: "info.circle")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Self.panelPadding)
        .padding(.vertical, Self.panelPadding * 0.75)
        #if !os(tvOS)
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

    #if os(macOS)
    private var volumeControl: some View {
        HStack(spacing: 6) {
            Button {
                engine.toggleMute()
                onInteraction()
            } label: {
                Image(systemName: volumeIcon)
                    .font(.callout.weight(.semibold))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .help("Tắt / bật tiếng (M)")
            Slider(value: Binding(get: { engine.isMuted ? 0 : engine.volume }, set: { engine.setVolume($0); onInteraction() }),
                   in: 0...130)
                .controlSize(.mini)
                .frame(width: 84)
                .tint(.white)
        }
        .padding(.trailing, 4)
    }

    private var volumeIcon: String {
        if engine.isMuted || engine.volume < 1 { return "speaker.slash.fill" }
        if engine.volume < 40 { return "speaker.wave.1.fill" }
        if engine.volume < 80 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
    #endif

    private func panelButton(_ target: PlayerPanel, icon: String) -> some View {
        Button {
            panel = panel == target ? nil : target
            onInteraction()
        } label: {
            barIcon(icon, text: target.title, active: panel == target)
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        .help(target.title + (target == .info ? " (I)" : ""))
        #endif
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(engine.chapters) { chapter in
                Button {
                    engine.selectChapter(chapter.id)
                    onInteraction()
                } label: {
                    let text = "\(TimeFormat.clock(chapter.time))  \(chapter.title)"
                    if chapter.id == engine.currentChapter {
                        Label(text, systemImage: "checkmark")
                    } else {
                        Text(text)
                    }
                }
            }
        } label: {
            barIcon("list.bullet.rectangle", text: "Chương")
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
    }

    private var optionsMenu: some View {
        Menu {
            Section("Tốc độ: \(Self.speedText(engine.speed))") {
                ForEach(Self.speeds, id: \.self) { value in
                    Button {
                        engine.setSpeed(value)
                        onInteraction()
                    } label: {
                        if abs(engine.speed - value) < 0.01 {
                            Label(Self.speedText(value), systemImage: "checkmark")
                        } else {
                            Text(Self.speedText(value))
                        }
                    }
                }
            }
            Section("Khung hình") {
                ForEach(VideoFit.allCases) { fit in
                    Button {
                        engine.setVideoFit(fit)
                        onInteraction()
                    } label: {
                        if engine.videoFit == fit {
                            Label(fit.label, systemImage: "checkmark")
                        } else {
                            Text(fit.label)
                        }
                    }
                }
            }
            Section("Cỡ phụ đề: \(Int((engine.subtitleScale * 100).rounded()))%") {
                Button { engine.adjustSubtitleScale(by: 0.1); onInteraction() } label: { Label("Lớn hơn", systemImage: "textformat.size.larger") }
                Button { engine.adjustSubtitleScale(by: -0.1); onInteraction() } label: { Label("Nhỏ hơn", systemImage: "textformat.size.smaller") }
            }
        } label: {
            barIcon("slider.horizontal.3", text: "Tuỳ chọn")
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
    }

    private var nightModeButton: some View {
        Button {
            engine.setNightMode(!engine.nightMode)
            onInteraction()
        } label: {
            barIcon(engine.nightMode ? "moon.fill" : "moon", text: engine.nightMode ? "Night Mode: Bật" : "Night Mode", active: engine.nightMode)
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        .help("Night Mode — nén dải động, nghe rõ thoại")
        #endif
    }

    private func barIcon(_ icon: String, text: String, active: Bool = false) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.weight(.semibold))
            #if !os(tvOS)
            .labelStyle(.iconOnly)
            .foregroundStyle(active ? Theme.leaf : .white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.white.opacity(active ? 0.16 : 0.001)))
            .contentShape(Circle())
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

    // MARK: Side panels

    private func sidePanel(_ current: PlayerPanel) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(current.title).font(.title3.weight(.bold))
                    Spacer()
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
                    #endif
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)

                ScrollView {
                    switch current {
                    case .tracks:
                        TracksPanel(engine: engine, onInteraction: onInteraction)
                    case .info:
                        InfoPanel(engine: engine)
                    }
                }
            }
            .frame(width: Self.panelWidth)
            .frame(maxHeight: .infinity)
            #if os(tvOS)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            #else
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
            #endif
            .foregroundStyle(.white)
        }
        .padding(.horizontal, Self.edge)
        .padding(.top, Self.edge * 0.6 + 52)
        .padding(.bottom, Self.edge * 0.6 + Self.bottomPanelHeight)
    }

    // MARK: Helpers

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

    private var progress: Double {
        engine.duration > 0 ? min(1, engine.position / engine.duration) : 0
    }

    private var bufferedProgress: Double {
        engine.duration > 0 ? min(1, (engine.position + engine.bufferedSeconds) / engine.duration) : 0
    }

    private var chapterMarks: [Double] {
        guard engine.duration > 0 else { return [] }
        return engine.chapters.map { $0.time / engine.duration }.filter { $0 > 0.005 && $0 < 0.995 }
    }

    private static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func speedText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
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
    private static let panelWidth: CGFloat = 720
    private static let timeWidth: CGFloat = 110
    private static let bottomPanelHeight: CGFloat = 170
    #else
    private static let edge: CGFloat = 20
    private static let panelPadding: CGFloat = 18
    private static let rowSpacing: CGFloat = 8
    private static let panelWidth: CGFloat = 380
    private static let timeWidth: CGFloat = 52
    private static let bottomPanelHeight: CGFloat = 110
    #endif
}

// MARK: - Scrub bar

#if !os(tvOS)
/// Thin Infuse-like scrubber: grows on hover/drag, shows buffered range, chapter ticks and a time bubble.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    let bufferedUntil: Double
    let marks: [Double]
    let chapters: [Chapter]
    @Binding var scrubPosition: Double?
    let onCommit: (Double) -> Void
    let onInteraction: () -> Void

    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let shown = scrubPosition ?? position
            let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
            let buffered = duration > 0 ? min(1, max(0, bufferedUntil / duration)) : 0
            let active = scrubPosition != nil || hoverX != nil

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
                if let x = scrubPosition.map({ CGFloat($0 / max(duration, 1)) * width }) ?? hoverX {
                    let time = Double(x / width) * duration
                    VStack(spacing: 2) {
                        if let chapter = chapterTitle(at: time) {
                            Text(chapter).font(.caption2).lineLimit(1)
                        }
                        Text(TimeFormat.clock(time)).font(.caption.weight(.semibold).monospacedDigit())
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
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case let .active(point): hoverX = min(max(0, point.x), width)
                case .ended: hoverX = nil
                }
            }
            #endif
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 26)
    }

    private func chapterTitle(at time: Double) -> String? {
        chapters.last { $0.time <= time }?.title
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

// MARK: - Panels

/// Audio and subtitle tracks plus sync offsets, in one list (like Infuse's track picker).
struct TracksPanel: View {
    @ObservedObject var engine: MPVPlayerEngine
    let onInteraction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Âm thanh") {
                if engine.audioTracks.isEmpty {
                    Text("Không có track âm thanh").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(engine.audioTracks) { track in
                    choice(track.label, selected: track.isSelected) { engine.selectAudioTrack(track.id) }
                }
            }
            group("Phụ đề") {
                choice("Tắt", selected: engine.subtitleTracks.allSatisfy { !$0.isSelected }) { engine.selectSubtitleTrack(nil) }
                ForEach(engine.subtitleTracks) { track in
                    choice(track.label, selected: track.isSelected) { engine.selectSubtitleTrack(track.id) }
                }
            }
            #if os(macOS)
            if engine.audioDevices.count > 1 {
                group("Thiết bị phát") {
                    ForEach(engine.audioDevices) { device in
                        choice(device.description, selected: device.id == engine.audioDevice) { engine.selectAudioDevice(device.id) }
                    }
                }
            }
            #endif
            group("Đồng bộ") {
                stepper("Phụ đề", value: String(format: "%+.1f s", engine.subtitleDelay),
                        minus: { engine.adjustSubtitleDelay(by: -0.1) }, plus: { engine.adjustSubtitleDelay(by: 0.1) },
                        reset: { engine.resetSubtitleDelay() })
                stepper("Âm thanh", value: String(format: "%+.0f ms", engine.audioDelay * 1000),
                        minus: { engine.adjustAudioDelay(by: -0.05) }, plus: { engine.adjustAudioDelay(by: 0.05) },
                        reset: { engine.resetAudioDelay() })
                #if !os(tvOS)
                Text("Phím tắt: Z / X lệch phụ đề ±0.1 s").font(.caption).foregroundStyle(.secondary)
                #endif
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .onAppear { engine.refreshAudioDevices() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func choice(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(Theme.leaf)
                    .opacity(selected ? 1 : 0)
                Text(text).font(.callout).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
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

    private func stepper(_ title: String, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void,
                         reset: @escaping () -> Void) -> some View {
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
        Button {
            action()
            onInteraction()
        } label: {
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

/// Technical details of what is playing, and the tail of the libmpv log (copyable for bug reports).
struct InfoPanel: View {
    @ObservedObject var engine: MPVPlayerEngine
    @State private var logLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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
