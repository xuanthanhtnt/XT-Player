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
    #if !os(tvOS)
    @StateObject private var airPlay = AirPlayController()
    #endif
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
    @State private var panel: PlayerPanel?
    @State private var lastPointerReset = Date.distantPast
    @State private var pointerOnControls = false
    #if os(tvOS)
    @FocusState private var surfaceFocused: Bool
    #endif
    #if os(macOS)
    @StateObject private var window = PlayerWindowController()
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

            PlayerSurface(engine: engine, videoAspect: engine.video.displayAspect, fit: engine.videoFit)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            inputLayer

            #if os(macOS)
            if controlsVisible {
                // Fades out (rather than vanishing) once the window is in full screen.
                titleBand
                    .opacity(isFullScreen ? 0 : 1)
                    .animation(.easeInOut(duration: 0.3), value: isFullScreen)
                    .transition(.opacity)
            }
            #endif

            if controlsVisible && !airPlayActive {
                PlayerControlsOverlay(
                    engine: engine,
                    title: current.title,
                    subtitle: current.subtitle,
                    resumedFrom: current.startAt,
                    hasNext: next != nil,
                    hasPrevious: index > 0,
                    skipBack: Double(skipBack),
                    skipForward: Double(skipForward),
                    panel: $panel,
                    isFullScreen: isFullScreen,
                    isMini: isMini,
                    topInset: titlebarHeight,
                    onClose: close,
                    onNext: { advance(by: 1) },
                    onPrevious: { advance(by: -1) },
                    onToggleFullScreen: toggleFullScreen,
                    onToggleMini: toggleMini,
                    onHoverControls: { inside in
                        pointerOnControls = inside
                        if !inside { scheduleHide() }
                    },
                    onInteraction: scheduleHide,
                    airPlay: airPlayController
                )
                .transition(.opacity)
            }

            #if !os(tvOS)
            if airPlay.isActive {
                AirPlayActiveView(controller: airPlay, title: current.title, onClose: close)
                    .transition(.opacity)
            }
            #endif

            if engine.isBuffering || engine.state == .loading {
                VStack(spacing: 12) {
                    ProgressView()
                        #if !os(tvOS)
                        .controlSize(.large)
                        #endif
                        .tint(.white)
                    if engine.isBuffering && engine.bufferingProgress > 0 {
                        Text("\(engine.bufferingProgress)%")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
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
        #if !os(tvOS)
        .alert("AirPlay", isPresented: Binding(get: { airPlay.message != nil }, set: { if !$0 { airPlay.message = nil } })) {
            Button("OK", role: .cancel) { airPlay.message = nil }
        } message: {
            Text(airPlay.message ?? "")
        }
        #endif
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
            if panel != nil {
                panel = nil
                scheduleHide()
            } else if upNextCountdown != nil {
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
        #if os(macOS)
        // Infuse / QuickTime behaviour: moving the pointer reveals the controls, idling hides them and the cursor.
        .onContinuousHover { phase in
            if case .active = phase { pointerMoved() }
        }
        .background(WindowReader { window.attach($0) })
        // The window takes the video's shape (no bars), and the traffic lights fade with the controls.
        .onChange(of: engine.video.displayAspect) { _, aspect in window.setVideoAspect(aspect) }
        .onChange(of: controlsVisible) { _, visible in window.setTitlebarButtonsVisible(visible) }
        #endif
    }

    #if os(macOS)
    private var isFullScreen: Bool { window.isFullScreen }
    private var isMini: Bool { window.isMini }
    private var titlebarHeight: CGFloat { window.titlebarHeight }

    /// The window's (transparent) title bar, Infuse-style: frosted band with the title in the middle.
    private var titleBand: some View {
        VStack(spacing: 0) {
            Text(current.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 86) // clear of the traffic lights
                .frame(maxWidth: .infinity)
                .frame(height: titlebarHeight)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.black.opacity(0.25)).frame(height: 0.5)
                }
                .environment(\.colorScheme, .dark)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
    #else
    private var isFullScreen: Bool { false }
    private var isMini: Bool { false }
    private var titlebarHeight: CGFloat { 0 }
    #endif

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
            Button("") { toggleFullScreen() }.keyboardShortcut("f", modifiers: [])
            Button("") { engine.toggleMute(); showControls() }.keyboardShortcut("m", modifiers: [])
            Button("") { togglePanel(.info) }.keyboardShortcut("i", modifiers: [])
            Button("") { togglePanel(.subtitles) }.keyboardShortcut("t", modifiers: [])
            Button("") { togglePanel(.audio) }.keyboardShortcut("a", modifiers: [])
            Button("") { escape() }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
    #endif

    private func escape() {
        if panel != nil {
            panel = nil
            scheduleHide()
        } else if isMini {
            toggleMini()
        } else if isFullScreen {
            toggleFullScreen()
        } else {
            close()
        }
    }

    private func togglePanel(_ target: PlayerPanel) {
        panel = panel == target ? nil : target
        showControls()
    }

    private func toggleFullScreen() {
        #if os(macOS)
        window.toggleFullScreen()
        showControls()
        #endif
    }

    private func toggleMini() {
        #if os(macOS)
        window.toggleMini()
        showControls()
        #endif
    }

    #if os(macOS)
    private func pointerMoved() {
        if !controlsVisible {
            showControls()
        } else if Date().timeIntervalSince(lastPointerReset) > 0.5 {
            lastPointerReset = Date()
            scheduleHide()
        }
    }
    #endif

    private func doubleTap(at fraction: CGFloat) {
        #if os(macOS)
        if isMini { toggleMini() } else { toggleFullScreen() }
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
        #if !os(tvOS)
        airPlay.currentPosition = { [engine] in engine.position }
        airPlay.onStart = { [engine] in engine.pause() }
        airPlay.onFinish = { [engine] position in
            engine.seek(to: position)
            engine.play()
        }
        #endif
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
        #if !os(tvOS)
        if airPlay.isActive { airPlay.shutdown() }
        airPlay.location = item.source.playbackLocation
        #endif
        engine.load(item.source.playbackLocation, startAt: item.startAt, externalSubtitles: item.externalSubtitles)
        nowPlaying.setItem(title: item.title, subtitle: item.subtitle,
                           artworkURL: TMDbClient.imageURL(item.artworkPath, size: "w780"))
        showControls()
    }

    private func stop() {
        hideTask?.cancel()
        cancelUpNext()
        saveProgress()
        #if !os(tvOS)
        airPlay.shutdown()
        #endif
        nowPlaying.detach()
        engine.shutdown()
        access = nil
        #if os(macOS)
        window.detach()
        #endif
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    private func close() {
        saveProgress()
        onClose()
    }

    private func saveProgress() {
        #if !os(tvOS)
        if airPlay.isActive, let entry, airPlay.duration > 0 {
            MediaLibrary.saveProgress(entry, position: airPlay.position, duration: airPlay.duration, in: context)
            return
        }
        #endif
        guard let entry, engine.duration > 0 || engine.position > 0 else { return }
        let finished = engine.state == .ended
        MediaLibrary.saveProgress(entry, position: finished ? engine.duration : engine.position, duration: engine.duration, in: context)
    }

    private var airPlayActive: Bool {
        #if os(tvOS)
        return false
        #else
        return airPlay.isActive
        #endif
    }

    #if os(tvOS)
    private var airPlayController: Void? { nil }
    #else
    private var airPlayController: AirPlayController? { airPlay }
    #endif

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
        #if !os(tvOS)
        if airPlay.isActive { return airPlay.togglePlayback() }
        #endif
        if engine.state == .ended {
            engine.seek(to: 0)
            engine.play()
        } else {
            engine.togglePause()
        }
    }

    private func jump(_ seconds: Double) {
        #if !os(tvOS)
        if airPlay.isActive { return airPlay.seek(by: seconds) }
        #endif
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
        panel = nil
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(true)
        #endif
        #if os(tvOS)
        // The catcher button is enabled in the same update; focus it on the next runloop turn.
        DispatchQueue.main.async { surfaceFocused = true }
        #endif
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, engine.state == .playing, panel == nil, !pointerOnControls else { return }
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
