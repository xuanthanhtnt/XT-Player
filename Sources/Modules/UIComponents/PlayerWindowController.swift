#if os(macOS)
import AppKit
import SwiftUI

/// Infuse-style window behaviour while a video plays on the Mac:
/// - the window takes the video's shape (and keeps it while resizing), so a windowed video has no bars;
/// - the traffic lights fade out together with the player controls;
/// - the PiP button turns the window into a small always-on-top player in the corner of the screen.
/// Everything is put back when the player closes.
@MainActor
final class PlayerWindowController: NSObject, ObservableObject {
    @Published private(set) var isFullScreen = false
    @Published private(set) var isMini = false
    /// Height of the transparent title bar that lies over the top of the video (0 in full screen).
    @Published private(set) var titlebarHeight: CGFloat = 28

    private weak var window: NSWindow?
    private var frameBeforePlayback: NSRect?
    private var frameBeforeMini: NSRect?
    private var levelBeforeMini: NSWindow.Level = .normal
    private var aspect: CGFloat = 0
    private var miniAfterFullScreen = false

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        let fullScreen = window.styleMask.contains(.fullScreen)
        frameBeforePlayback = fullScreen ? nil : window.frame
        isFullScreen = fullScreen
        refreshTitlebarHeight()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willEnterFullScreen(_:)), name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didEnterFullScreen(_:)), name: NSWindow.didEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didExitFullScreen(_:)), name: NSWindow.didExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didResize(_:)), name: NSWindow.didResizeNotification, object: window)
        applyAspect(resize: true)
    }

    /// Restores the window as it was before playback.
    func detach() {
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        setTitlebarButtonsVisible(true, animated: false)
        window.contentResizeIncrements = NSSize(width: 1, height: 1) // clears the aspect-ratio lock
        if isMini { window.level = levelBeforeMini }
        if !window.styleMask.contains(.fullScreen), let frame = frameBeforePlayback, frame != window.frame {
            window.setFrame(frame, display: true, animate: true)
        }
        self.window = nil
        frameBeforePlayback = nil
        frameBeforeMini = nil
        miniAfterFullScreen = false
        isMini = false
        aspect = 0
    }

    // MARK: Video shape

    /// Called whenever mpv reports the picture's display aspect ratio (a new file may change it).
    func setVideoAspect(_ value: Double) {
        let value = CGFloat(value)
        guard value.isFinite, value > 0.2, value < 6, abs(value - aspect) > 0.001 else { return }
        aspect = value
        applyAspect(resize: true)
    }

    private func applyAspect(resize: Bool) {
        guard let window, aspect > 0, !window.styleMask.contains(.fullScreen) else { return }
        // The content view spans the whole window (transparent title bar), so this is the video's shape.
        window.contentAspectRatio = NSSize(width: (aspect * 1000).rounded(), height: 1000)
        if resize { resizeToAspect() }
    }

    /// Keeps the width (or the mini size) and the top-left corner, fits the height to the video.
    private func resizeToAspect() {
        guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let shape = aspect > 0 ? aspect : 16.0 / 9.0
        let current = window.contentRect(forFrameRect: window.frame)
        let wanted = isMini ? max(400, (visible.width * 0.3).rounded()) : current.width
        let limit = window.contentRect(forFrameRect: visible).size
        var size = NSSize(width: wanted, height: wanted / shape)
        if size.height > limit.height { size = NSSize(width: limit.height * shape, height: limit.height) }
        if size.width > limit.width { size = NSSize(width: limit.width, height: limit.width / shape) }
        size = NSSize(width: size.width.rounded(), height: size.height.rounded())

        let content = isMini
            ? NSRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height)
            : NSRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
        var frame = window.frameRect(forContentRect: content)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        guard frame.integral != window.frame.integral else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: Full screen & mini player

    func toggleFullScreen() {
        guard let window else { return }
        if isMini { exitMini() }
        window.toggleFullScreen(nil)
    }

    func toggleMini() {
        guard let window else { return }
        if isMini {
            exitMini()
        } else if window.styleMask.contains(.fullScreen) {
            miniAfterFullScreen = true
            window.toggleFullScreen(nil)
        } else {
            enterMini()
        }
    }

    private func enterMini() {
        guard let window, !isMini else { return }
        frameBeforeMini = window.frame
        levelBeforeMini = window.level
        isMini = true
        window.level = .floating
        resizeToAspect()
    }

    private func exitMini() {
        guard let window, isMini else { return }
        isMini = false
        window.level = levelBeforeMini
        if let frame = frameBeforeMini { window.setFrame(frame, display: true, animate: true) }
        frameBeforeMini = nil
    }

    @objc private func willEnterFullScreen(_ notification: Notification) {
        guard let window else { return }
        if isMini {
            isMini = false
            window.level = levelBeforeMini
        }
        // Full screen fills the screen; the aspect lock comes back afterwards.
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        setTitlebarButtonsVisible(true, animated: false)
    }

    @objc private func didEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        refreshTitlebarHeight()
    }

    @objc private func didExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        refreshTitlebarHeight()
        if miniAfterFullScreen {
            miniAfterFullScreen = false
            applyAspect(resize: false)
            enterMini()
        } else {
            applyAspect(resize: true)
        }
    }

    @objc private func didResize(_ notification: Notification) {
        refreshTitlebarHeight()
    }

    // MARK: Title bar

    /// Fades the close / minimise / zoom buttons with the player controls (windowed only).
    func setTitlebarButtonsVisible(_ visible: Bool, animated: Bool = true) {
        refreshTitlebarHeight()
        guard let window, let buttons = window.standardWindowButton(.closeButton)?.superview else { return }
        if !visible, window.styleMask.contains(.fullScreen) { return }
        let alpha: CGFloat = visible ? 1 : 0
        guard buttons.alphaValue != alpha else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                buttons.animator().alphaValue = alpha
            }
        } else {
            buttons.alphaValue = alpha
        }
    }

    private func refreshTitlebarHeight() {
        guard let window else { return }
        let height = window.styleMask.contains(.fullScreen)
            ? 0
            : min(60, max(22, window.frame.height - window.contentLayoutRect.height))
        if abs(height - titlebarHeight) > 0.5 { titlebarHeight = height }
    }
}

/// Hands the NSWindow that hosts a SwiftUI view to `onWindow` (once it is in a window).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindow = onWindow
        if let window = nsView.window { nsView.report(window) }
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private weak var reported: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { report(window) }
        }

        func report(_ window: NSWindow) {
            guard reported !== window else { return }
            reported = window
            // Outside the SwiftUI update that inserted this view.
            DispatchQueue.main.async { [weak self] in self?.onWindow?(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
