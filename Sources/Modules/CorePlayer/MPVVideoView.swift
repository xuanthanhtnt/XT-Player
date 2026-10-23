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
final class MPVVideoView: PlatformView {
    let metalLayer = MPVMetalLayer()

    #if os(iOS) || os(tvOS)
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = UIScreen.main.nativeScale
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
    }
    #else
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.framebufferOnly = true
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
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
