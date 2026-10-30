#if !os(tvOS)
import AVFoundation
import AVKit
import Combine
import SwiftUI

/// AirPlay to an Apple TV or AirPlay TV. libmpv draws into this device's Metal layer, so for AirPlay the item is
/// handed to AVPlayer's external playback and the TV pulls the file from `LocalStreamServer` on this device.
/// The TV plays what AVFoundation plays (MP4 / MOV / M4V with H.264 or HEVC); other files report a message.
///
/// The AVPlayer item is only prepared while the AirPlay menu is open, so normal playback costs nothing.
@MainActor
final class AirPlayController: NSObject, ObservableObject, AVRoutePickerViewDelegate {
    @Published private(set) var isActive = false
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var deviceName = ""
    @Published var message: String?

    let player = AVPlayer()

    /// What is playing locally, set by the player screen.
    var location: String?
    var currentPosition: () -> Double = { 0 }
    /// AirPlay took over: pause libmpv.
    var onStart: () -> Void = {}
    /// AirPlay ended: resume libmpv at this position.
    var onFinish: (Double) -> Void = { _ in }

    private var token: String?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var discardTask: Task<Void, Never>?

    override init() {
        super.init()
        player.allowsExternalPlayback = true
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in self?.externalPlaybackChanged(active) }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite { self.duration = seconds }
            }
        }
    }

    // MARK: Controls (while on the TV)

    func togglePlayback() {
        isPlaying ? player.pause() : player.play()
    }

    func seek(by seconds: Double) {
        seek(to: position + seconds)
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Brings playback back to this device.
    func stop() {
        player.allowsExternalPlayback = false
        // The external route closes asynchronously; allow AirPlay again for the next time.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.player.allowsExternalPlayback = true
        }
        if isActive { externalPlaybackChanged(false) }
    }

    /// The player screen is closing.
    func shutdown() {
        player.pause()
        discardTask?.cancel()
        teardown()
        isActive = false
    }

    // MARK: AVRoutePickerViewDelegate

    nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        MainActor.assumeIsolated { prepare() }
    }

    nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        MainActor.assumeIsolated {
            // No TV picked: drop the item again (the route switch itself can take a few seconds).
            discardTask?.cancel()
            discardTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, !self.isActive else { return }
                self.teardown()
            }
        }
    }

    // MARK: Private

    private func prepare() {
        discardTask?.cancel()
        guard player.currentItem == nil, let location else { return }
        guard let published = LocalStreamServer.shared.publish(location: location) else {
            message = "Không chia sẻ được tệp cho AirPlay — thiết bị cần ở cùng mạng Wi-Fi / LAN với TV."
            return
        }
        token = published.token
        let item = AVPlayerItem(url: published.url)
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription ?? ""
            Task { @MainActor in self?.itemFailed(reason) }
        })
        player.replaceCurrentItem(with: item)
        player.seek(to: CMTime(seconds: currentPosition(), preferredTimescale: 600))
    }

    private func externalPlaybackChanged(_ active: Bool) {
        if active, !isActive, player.currentItem != nil {
            isActive = true
            message = nil
            deviceName = Self.routeName()
            onStart()
            player.seek(to: CMTime(seconds: currentPosition(), preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor in self?.player.play() }
            }
        } else if !active, isActive {
            isActive = false
            let resumeAt = position
            player.pause()
            teardown()
            onFinish(resumeAt)
        }
    }

    private func itemFailed(_ reason: String) {
        message = "TV không phát được tệp này qua AirPlay (AirPlay video cần MP4 / MOV với H.264 hoặc HEVC; MKV, AV1… thì chưa). "
            + "Hãy dùng Phản chiếu màn hình. \(reason)"
        if isActive {
            stop()
        } else {
            teardown()
        }
    }

    private func teardown() {
        player.replaceCurrentItem(with: nil)
        if let token { LocalStreamServer.shared.unpublish(token) }
        token = nil
    }

    private static func routeName() -> String {
        #if os(iOS)
        if let output = AVAudioSession.sharedInstance().currentRoute.outputs.first(where: { $0.portType == .airPlay }) {
            return output.portName
        }
        #endif
        return "TV AirPlay"
    }
}

/// The system AirPlay button (lists Apple TVs and AirPlay TVs), wired to `AirPlayController`.
struct AirPlayButton: View {
    @ObservedObject var controller: AirPlayController
    var size: CGFloat = 30

    var body: some View {
        RoutePicker(controller: controller)
            .frame(width: size, height: size)
            .help("AirPlay — phát lên Apple TV / TV AirPlay")
    }
}

#if os(macOS)
private struct RoutePicker: NSViewRepresentable {
    let controller: AirPlayController

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = controller.player
        view.delegate = controller
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(NSColor(Theme.leaf), for: .active)
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#else
private struct RoutePicker: UIViewRepresentable {
    let controller: AirPlayController

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.delegate = controller
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.leaf)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
#endif
