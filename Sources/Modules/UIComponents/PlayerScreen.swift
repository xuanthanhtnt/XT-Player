import SwiftData
import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

struct PlayerScreen: View {
    let session: PlaybackSession
    let onClose: () -> Void

    @StateObject private var engine = MPVPlayerEngine()
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.autoplayNext) private var autoplayNext = true
    @AppStorage(AppSettings.skipBackSeconds) private var skipBack = 10
    @AppStorage(AppSettings.skipForwardSeconds) private var skipForward = 30
    @State private var index = 0
    @State private var entry: MediaEntry?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var access: SecurityScopedAccess?
    @State private var seekFlash: String?
    @State private var upNextCountdown: Int?
    @State private var upNextTask: Task<Void, Never>?
    @State private var scrubDelta: Double?
    @State private var nowPlaying = NowPlayingController()
    #if os(tvOS)
    @FocusState private var surfaceFocused: Bool
    #endif

    init(session: PlaybackSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _index = State(initialValue: session.startIndex)
    }

    private var current: PlaybackItem { session.items[min(index, session.items.count - 1)] }
    private var next: PlaybackItem? { index + 1 < session.items.count ? session.items[index + 1] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerSurface(engine: engine)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            inputLayer

            if controlsVisible {
                PlayerControlsOverlay(
                    engine: engine,
                    title: current.title,
                    subtitle: current.subtitle,
                    resumedFrom: current.startAt,
                    hasNext: next != nil,
                    hasPrevious: index > 0,
                    skipBack: Double(skipBack),
                    skipForward: Double(skipForward),
                    onClose: close,
                    onNext: { advance(by: 1) },
                    onPrevious: { advance(by: -1) },
                    onInteraction: scheduleHide
                )
                .transition(.opacity)
            }

            if engine.isBuffering || engine.state == .loading {
                ProgressView()
                    #if !os(tvOS)
                    .controlSize(.large)
                    #endif
                    .tint(.white)
                    .padding(28)
                    .glassPanel(cornerRadius: 24)
                    .allowsHitTesting(false)
            }

            if let text = seekFlash ?? scrubText {
                Text(text)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .glassPanel(cornerRadius: 18)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if let countdown = upNextCountdown, let next {
                upNextCard(next, countdown: countdown)
            }

            if case let .failed(message) = engine.state {
                errorPanel(message)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: upNextCountdown != nil)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress() }
        }
        .onChange(of: engine.state) { _, state in
            switch state {
            case .ended:
                saveProgress()
                if next != nil, autoplayNext { startUpNext() } else { showControls(autoHide: false) }
            case .paused:
                showControls(autoHide: false)
            default:
                break
            }
        }
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        #if os(tvOS)
        .onPlayPauseCommand {
            togglePlayback()
            showControls()
        }
        .onExitCommand {
            if upNextCountdown != nil {
                cancelUpNext()
            } else if controlsVisible, engine.state == .playing {
                hideControls()
            } else {
                close()
            }
        }
        #else
        .background(keyboardShortcuts)
        #endif
    }

    // MARK: Input

    @ViewBuilder
    private var inputLayer: some View {
        #if os(tvOS)
        // Catches the Siri Remote while the overlay is hidden: click = controls, left/right = skip.
        Button { showControls() } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(InvisibleButtonStyle())
        .focused($surfaceFocused)
        .disabled(controlsVisible)
        .onMoveCommand { direction in
            switch direction {
            case .left: jump(-Double(skipBack))
            case .right: jump(Double(skipForward))
            default: showControls()
            }
        }
        #else
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in doubleTap(at: value.location.x / max(1, geo.size.width)) }
                        .exclusively(before: TapGesture().onEnded { controlsVisible ? hideControls() : showControls() })
                )
                #if os(iOS)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            // A full-width swipe spans three minutes.
                            scrubDelta = Double(value.translation.width / max(1, geo.size.width)) * 180
                        }
                        .onEnded { _ in
                            if let delta = scrubDelta { engine.seek(by: delta) }
                            scrubDelta = nil
                        }
                )
                #endif
        }
        .ignoresSafeArea()
        #endif
    }

    #if !os(tvOS)
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { togglePlayback(); showControls() }.keyboardShortcut(.space, modifiers: [])
            Button("") { jump(-Double(skipBack)) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { jump(Double(skipForward)) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { jump(-60) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { jump(60) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { advance(by: 1) }.keyboardShortcut("n", modifiers: [])
            Button("") { engine.adjustSubtitleDelay(by: -0.1) }.keyboardShortcut("z", modifiers: [])
            Button("") { engine.adjustSubtitleDelay(by: 0.1) }.keyboardShortcut("x", modifiers: [])
            Button("") { close() }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
    #endif

    private func doubleTap(at fraction: CGFloat) {
        #if os(macOS)
        NSApp.keyWindow?.toggleFullScreen(nil)
        #else
        if fraction < 0.35 {
            jump(-Double(skipBack))
        } else if fraction > 0.65 {
            jump(Double(skipForward))
        } else {
            togglePlayback()
        }
        #endif
    }

    private var scrubText: String? {
        guard let scrubDelta else { return nil }
        let target = max(0, min(engine.duration, engine.position + scrubDelta))
        let sign = scrubDelta >= 0 ? "+" : "−"
        return "\(TimeFormat.clock(target))  (\(sign)\(TimeFormat.clock(abs(scrubDelta))))"
    }

    // MARK: Lifecycle

    private func start() {
        nowPlaying.attach(to: engine)
        nowPlaying.onNext = { advance(by: 1) }
        nowPlaying.onPrevious = { advance(by: -1) }
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        load(current)
    }

    private func load(_ item: PlaybackItem) {
        cancelUpNext()
        access = SecurityScopedAccess(item.source.url)
        if let server = item.server { RemoteCredentialStore.shared.register(server) }
        entry = MediaLibrary.touch(item, in: context)
        try? context.save()
        engine.load(item.source.playbackLocation, startAt: item.startAt, externalSubtitles: item.externalSubtitles)
        nowPlaying.setItem(title: item.title, subtitle: item.subtitle,
                           artworkURL: TMDbClient.imageURL(item.artworkPath, size: "w780"))
        showControls()
    }

    private func stop() {
        hideTask?.cancel()
        cancelUpNext()
        saveProgress()
        nowPlaying.detach()
        engine.shutdown()
        access = nil
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    private func close() {
        saveProgress()
        onClose()
    }

    private func saveProgress() {
        guard let entry, engine.duration > 0 || engine.position > 0 else { return }
        let finished = engine.state == .ended
        MediaLibrary.saveProgress(entry, position: finished ? engine.duration : engine.position, duration: engine.duration, in: context)
    }

    private func advance(by step: Int) {
        let target = index + step
        guard target >= 0, target < session.items.count else { return }
        saveProgress()
        index = target
        load(session.items[target])
    }

    // MARK: Up Next

    private func startUpNext() {
        upNextTask?.cancel()
        upNextCountdown = 10
        upNextTask = Task {
            while let remaining = upNextCountdown, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                upNextCountdown = remaining - 1
            }
            if !Task.isCancelled, upNextCountdown == 0 { advance(by: 1) }
        }
    }

    private func cancelUpNext() {
        upNextTask?.cancel()
        upNextTask = nil
        upNextCountdown = nil
    }

    private func upNextCard(_ item: PlaybackItem, countdown: Int) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 16) {
                    ArtworkImage(path: item.artworkPath, size: "w300", placeholderIcon: "tv")
                        .frame(width: 160, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tiếp theo sau \(countdown)s").font(.caption.weight(.semibold)).foregroundStyle(Theme.leaf)
                        Text(item.title).font(.headline).lineLimit(2)
                        HStack {
                            Button("Phát ngay") { advance(by: 1) }
                            #if !os(tvOS)
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                            #endif
                            Button("Huỷ") {
                                cancelUpNext()
                                showControls(autoHide: false)
                            }
                            #if !os(tvOS)
                            .buttonStyle(.bordered)
                            #endif
                        }
                    }
                }
                .padding(18)
                .glassPanel()
                .frame(maxWidth: 620)
            }
        }
        .padding(Theme.pagePadding)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    // MARK: Helpers

    private func togglePlayback() {
        if engine.state == .ended {
            engine.seek(to: 0)
            engine.play()
        } else {
            engine.togglePause()
        }
    }

    private func jump(_ seconds: Double) {
        engine.seek(by: seconds)
        withAnimation(.spring(duration: 0.25)) { seekFlash = seconds > 0 ? "+\(Int(seconds))s" : "\(Int(seconds))s" }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation { seekFlash = nil }
        }
    }

    private func showControls(autoHide: Bool = true) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func hideControls() {
        hideTask?.cancel()
        controlsVisible = false
        #if os(tvOS)
        // The catcher button is enabled in the same update; focus it on the next runloop turn.
        DispatchQueue.main.async { surfaceFocused = true }
        #endif
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, engine.state == .playing else { return }
            hideControls()
        }
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.danger)
            Text(message)
                .multilineTextAlignment(.center)
            HStack {
                if next != nil {
                    Button("Bỏ qua tệp này") { advance(by: 1) }
                }
                Button("Đóng", action: close)
                    #if !os(tvOS)
                    .buttonStyle(.borderedProminent)
                    #endif
            }
        }
        .padding(32)
        .frame(maxWidth: 560)
        .glassPanel()
    }
}
