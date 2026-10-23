import QuartzCore
import SwiftUI

#if os(iOS) || os(tvOS)
import UIKit
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformView = NSView
#endif

/// CAMetalLayer that libmpv (vo=gpu-next, gpu-api=vulkan via MoltenVK) renders into.
final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK briefly sets drawableSize to 1x1 to force-complete a presentation; ignoring it avoids
    // flicker and a stuck 1x1 swapchain (mpv-player/mpv#13651).
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    #if !os(tvOS)
    // target-colorspace-hint toggles EDR from mpv's render thread, but the display only switches to
    // EDR when the property changes on the main thread. (tvOS has no EDR flag: the PQ/HLG colorspace on
    // the layer plus AVDisplayManager's mode switch carry HDR there.)
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
    #endif
}

/// Platform view hosting the Metal layer.
///
/// MPVKit's MoltenVK context has no resize events: mpv only learns the surface size when a file is
/// (re)configured, and MoltenVK reports the swapchain "suboptimal" whenever the layer's
/// `bounds × contentsScale` stops matching it — libplacebo then rebuilds the swapchain at the new size
/// while mpv keeps drawing into the old rectangle (the picture stops following the window).
///
/// So the layer itself never changes size: its bounds are fixed at the screen's native pixel size
/// (contentsScale 1) and a Core Animation transform scales it to fit the view. Window resizing, full
/// screen and rotation are then pure compositor work, and the aspect ratio is always preserved.
final class MPVVideoView: PlatformView {
    let metalLayer = MPVMetalLayer()
    /// The (constant) render size mpv sees for the lifetime of this view.
    let surfaceSize = MPVVideoView.swapchainSize

    static var swapchainSize: CGSize {
        #if os(iOS) || os(tvOS)
        let native = UIScreen.main.nativeBounds.size
        return CGSize(width: max(native.width, native.height), height: min(native.width, native.height))
        #else
        let sizes = NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
        return sizes.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 3840, height: 2160)
        #endif
    }

    private func configureLayer() {
        metalLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = 1
        metalLayer.contentsGravity = .resize
        metalLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        metalLayer.bounds = CGRect(origin: .zero, size: surfaceSize)
        metalLayer.drawableSize = surfaceSize
    }

    /// Centres the fixed-size layer and scales it to fit `rect`.
    private func place(in rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if metalLayer.bounds.size != surfaceSize { metalLayer.bounds = CGRect(origin: .zero, size: surfaceSize) }
        if metalLayer.contentsScale != 1 { metalLayer.contentsScale = 1 }
        let scale = rect.width > 0 && rect.height > 0
            ? min(rect.width / surfaceSize.width, rect.height / surfaceSize.height)
            : 0.001
        metalLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        metalLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    #if os(iOS) || os(tvOS)
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        configureLayer()
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        place(in: bounds)
    }
    #else
    private let rootLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.masksToBounds = true
        configureLayer()
        rootLayer.addSublayer(metalLayer)
        layer = rootLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // SwiftUI changes the frame without necessarily running layout(), so follow every size change.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayer()
    }

    override func layout() {
        super.layout()
        syncLayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayer()
    }

    private func syncLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = bounds
        CATransaction.commit()
        place(in: bounds)
    }
    #endif
}

/// SwiftUI surface: creates the view and attaches it to the engine (mpv needs the layer before init).
#if os(iOS) || os(tvOS)
struct PlayerSurface: UIViewRepresentable {
    let engine: MPVPlayerEngine

    func makeUIView(context: Context) -> MPVVideoView {
        let view = MPVVideoView(frame: .zero)
        engine.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MPVVideoView, context: Context) {}
}
#else
struct PlayerSurface: NSViewRepresentable {
    let engine: MPVPlayerEngine

    func makeNSView(context: Context) -> MPVVideoView {
        let view = MPVVideoView(frame: .zero)
        engine.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: MPVVideoView, context: Context) {}
}
#endif
