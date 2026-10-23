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
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var access: SecurityScopedAccess?
    @State private var seekFlash: String?
    #if os(tvOS)
    @FocusState private var surfaceFocused: Bool
    #endif

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
                    title: session.title,
                    resumedFrom: session.startAt,
                    onClose: close,
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

            if let seekFlash {
                Text(seekFlash)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .glassPanel(cornerRadius: 18)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if case let .failed(message) = engine.state {
                errorPanel(message)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress() }
        }
        .onChange(of: engine.state) { _, state in
            if state == .ended || state == .paused { showControls(autoHide: false) }
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
            if controlsVisible, engine.state == .playing {
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
        // Catches the Siri Remote while the overlay is hidden: click = controls, left/right = ±10 s.
        Button { showControls() } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(InvisibleButtonStyle())
        .focused($surfaceFocused)
        .disabled(controlsVisible)
        .onMoveCommand { direction in
            switch direction {
            case .left: jump(-10)
            case .right: jump(10)
            default: showControls()
            }
        }
        #else
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture(count: 2) { toggleFullScreenGesture() }
            .onTapGesture { controlsVisible ? hideControls() : showControls() }
        #endif
    }

    #if !os(tvOS)
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { togglePlayback(); showControls() }.keyboardShortcut(.space, modifiers: [])
            Button("") { jump(-10) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { jump(10) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { jump(-60) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { jump(60) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { close() }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
    #endif

    private func toggleFullScreenGesture() {
        #if os(macOS)
        NSApp.keyWindow?.toggleFullScreen(nil)
        #else
        togglePlayback()
        #endif
    }

    // MARK: Lifecycle

    private func start() {
        access = SecurityScopedAccess(session.source.url)
        engine.load(session.source.playbackLocation, startAt: session.startAt)
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        scheduleHide()
    }

    private func stop() {
        hideTask?.cancel()
        saveProgress()
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
        guard let entry = session.entry, engine.duration > 0 || engine.position > 0 else { return }
        MediaLibrary.saveProgress(entry, position: engine.position, duration: engine.duration, in: context)
    }

    // MARK: Playback helpers

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
                .foregroundStyle(Theme.brandGradient)
            Text(message)
                .multilineTextAlignment(.center)
            Button("Đóng", action: close)
                #if !os(tvOS)
                .buttonStyle(.borderedProminent)
                #endif
        }
        .padding(32)
        .frame(maxWidth: 560)
        .glassPanel()
    }
}
