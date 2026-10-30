import Combine
import Foundation
import MediaPlayer
#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

/// Publishes the current item to Now Playing (Control Center, Lock Screen, AirPods, the macOS menu bar)
/// and routes remote commands back to the engine.
@MainActor
final class NowPlayingController {
    private weak var engine: MPVPlayerEngine?
    private var cancellables: Set<AnyCancellable> = []
    private var info: [String: Any] = [:]
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    func attach(to engine: MPVPlayerEngine) {
        self.engine = engine
        engine.$position
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.updatePlayback() }
            .store(in: &cancellables)
        engine.$state
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updatePlayback() } }
            .store(in: &cancellables)
        engine.$duration
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updatePlayback() } }
            .store(in: &cancellables)
        registerCommands()
    }

    func setItem(title: String, subtitle: String?, artworkURL: URL?, isMusic: Bool = false) {
        let type: MPNowPlayingInfoMediaType = isMusic ? .audio : .video
        info = [MPMediaItemPropertyTitle: title, MPNowPlayingInfoPropertyMediaType: type.rawValue]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        updatePlayback()
        guard let artworkURL else { return }
        Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: artworkURL).0 else { return }
            #if os(iOS) || os(tvOS)
            guard let image = UIImage(data: data) else { return }
            #else
            guard let image = NSImage(data: data) else { return }
            #endif
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self?.info[MPMediaItemPropertyArtwork] = artwork
            self?.updatePlayback()
        }
    }

    func detach() {
        cancellables.removeAll()
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func updatePlayback() {
        guard let engine, !info.isEmpty else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.position
        info[MPMediaItemPropertyPlaybackDuration] = engine.duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.state == .playing ? engine.speed : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = engine.state == .playing ? .playing : .paused
        #endif
    }

    private func registerCommands() {
        // tvOS delivers Siri Remote presses to the focused view; only phones/Macs need remote commands.
        #if os(iOS) || os(macOS)
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak self] _ in self?.engine?.play(); return .success }
        add(center.pauseCommand) { [weak self] _ in self?.engine?.pause(); return .success }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.engine?.togglePause(); return .success }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { [weak self] _ in self?.engine?.seek(by: 30); return .success }
        add(center.skipBackwardCommand) { [weak self] _ in self?.engine?.seek(by: -10); return .success }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.engine?.seek(to: event.positionTime)
            return .success
        }
        add(center.nextTrackCommand) { [weak self] _ in
            guard let next = self?.onNext else { return .noSuchContent }
            next()
            return .success
        }
        add(center.previousTrackCommand) { [weak self] _ in
            guard let previous = self?.onPrevious else { return .noSuchContent }
            previous()
            return .success
        }
        #endif
    }

    private func add(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let target = command.addTarget(handler: handler)
        commandTargets.append((command, target))
    }
}
