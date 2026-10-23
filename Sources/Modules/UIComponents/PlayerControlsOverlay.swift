import SwiftUI

/// Transport bar, signal info and track menus. Works with touch (iOS/iPadOS), pointer + keyboard (macOS)
/// and the Siri Remote focus engine (tvOS).
struct PlayerControlsOverlay: View {
    @ObservedObject var engine: MPVPlayerEngine
    let title: String
    let resumedFrom: Double?
    let onClose: () -> Void
    let onInteraction: () -> Void

    @State private var scrubPosition: Double?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 280)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                #if !os(tvOS)
                centerTransport
                Spacer(minLength: 0)
                #endif
                bottomBar
            }
            .padding(.horizontal, Self.edge)
            .padding(.vertical, Self.edge * 0.6)
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    #if !os(tvOS)
                    .frame(width: 44, height: 44)
                    .glassPanel(cornerRadius: 22)
                    #endif
            }
            #if !os(tvOS)
            .buttonStyle(.plain)
            #endif

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                SignalBadges(engine: engine)
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
        }
        .foregroundStyle(.white)
    }

    // MARK: Center (touch / pointer)

    #if !os(tvOS)
    private var centerTransport: some View {
        HStack(spacing: 48) {
            transportButton("gobackward.10", size: 30) { engine.seek(by: -10) }
            transportButton(playPauseIcon, size: 46) { togglePlayback() }
            transportButton("goforward.30", size: 30) { engine.seek(by: 30) }
        }
    }

    private func transportButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 2, height: size * 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            timeline
            HStack(spacing: 14) {
                #if os(tvOS)
                tvButton(playPauseIcon) { togglePlayback() }
                tvButton("gobackward.10") { engine.seek(by: -10) }
                tvButton("goforward.30") { engine.seek(by: 30) }
                #endif
                Spacer(minLength: 0)
                audioMenu
                subtitleMenu
                nightModeButton
            }
        }
        .foregroundStyle(.white)
    }

    private var timeline: some View {
        VStack(spacing: 6) {
            #if os(tvOS)
            ProgressTrack(progress: progress, buffered: bufferedProgress)
                .frame(height: 10)
            #else
            Slider(
                value: Binding(get: { scrubPosition ?? engine.position }, set: { scrubPosition = $0 }),
                in: 0...max(engine.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubPosition {
                        engine.seek(to: target)
                        scrubPosition = nil
                    }
                    onInteraction()
                }
            )
            .tint(Theme.accent)
            #endif
            HStack {
                Text(TimeFormat.clock(scrubPosition ?? engine.position))
                Spacer()
                if engine.bufferedSeconds > 0 {
                    Text("Bộ đệm \(Int(engine.bufferedSeconds))s")
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                }
                Text("-" + TimeFormat.clock(max(0, engine.duration - (scrubPosition ?? engine.position))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var audioMenu: some View {
        Menu {
            if engine.audioTracks.isEmpty {
                Text("Không có track âm thanh")
            }
            ForEach(engine.audioTracks) { track in
                Button {
                    engine.selectAudioTrack(track.id)
                    onInteraction()
                } label: {
                    if track.isSelected {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            menuLabel("Âm thanh", icon: "speaker.wave.2.fill")
        }
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                engine.selectSubtitleTrack(nil)
                onInteraction()
            } label: {
                if engine.subtitleTracks.allSatisfy({ !$0.isSelected }) {
                    Label("Tắt phụ đề", systemImage: "checkmark")
                } else {
                    Text("Tắt phụ đề")
                }
            }
            ForEach(engine.subtitleTracks) { track in
                Button {
                    engine.selectSubtitleTrack(track.id)
                    onInteraction()
                } label: {
                    if track.isSelected {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
            Section("Lệch phụ đề: \(String(format: "%+.1f", engine.subtitleDelay)) s") {
                Button { engine.adjustSubtitleDelay(by: -0.1); onInteraction() } label: {
                    Label("Sớm hơn 0.1 s", systemImage: "minus.circle")
                }
                Button { engine.adjustSubtitleDelay(by: 0.1); onInteraction() } label: {
                    Label("Trễ hơn 0.1 s", systemImage: "plus.circle")
                }
                Button { engine.resetSubtitleDelay(); onInteraction() } label: {
                    Label("Đặt lại", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            menuLabel("Phụ đề", icon: "captions.bubble.fill")
        }
    }

    private var nightModeButton: some View {
        Button {
            engine.setNightMode(!engine.nightMode)
            onInteraction()
        } label: {
            menuLabel(engine.nightMode ? "Night Mode: Bật" : "Night Mode", icon: engine.nightMode ? "moon.fill" : "moon")
        }
        #if !os(tvOS)
        .buttonStyle(.plain)
        #endif
    }

    private func menuLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.weight(.semibold))
            #if !os(tvOS)
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .glassPanel(cornerRadius: 22)
            .help(text)
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

    #if os(tvOS)
    private static let edge: CGFloat = 80
    #else
    private static let edge: CGFloat = 24
    #endif
}

/// Resolution · dynamic range · frame rate · codec · decoder · audio.
struct SignalBadges: View {
    @ObservedObject var engine: MPVPlayerEngine

    var body: some View {
        HStack(spacing: 6) {
            let video = engine.video
            if !video.resolutionLabel.isEmpty { TagChip(text: video.resolutionLabel) }
            if !video.gamma.isEmpty {
                TagChip(text: dynamicRangeText(video), highlighted: video.dynamicRange != .sdr)
            }
            if video.fps > 1 { TagChip(text: fpsText(video.fps)) }
            if !engine.videoCodec.isEmpty { TagChip(text: engine.videoCodec) }
            if engine.hardwareDecoder.hasPrefix("videotoolbox") { TagChip(text: "VideoToolbox") }
            if !engine.audio.codec.isEmpty {
                TagChip(text: engine.audio.codec + (engine.audio.channels > 0 ? " " + MediaTrack.channelLayout(engine.audio.channels) : ""))
            }
        }
    }

    private func fpsText(_ fps: Double) -> String {
        abs(fps - fps.rounded()) < 0.01 ? "\(Int(fps.rounded())) fps" : String(format: "%.3f fps", fps)
    }

    private func dynamicRangeText(_ video: VideoSignal) -> String {
        var text = video.dynamicRange.rawValue
        if video.dynamicRange == .dolbyVision, video.dolbyVisionProfile > 0 { text += " P\(video.dolbyVisionProfile)" }
        if video.dynamicRange != .sdr, !engine.hdrOutputActive { text += " → SDR" }
        return text
    }
}

#if os(tvOS)
private struct ProgressTrack: View {
    let progress: Double
    let buffered: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Color.white.opacity(0.28)).frame(width: geo.size.width * buffered)
                Capsule().fill(Theme.brandGradient).frame(width: max(10, geo.size.width * progress))
            }
        }
    }
}
#endif
