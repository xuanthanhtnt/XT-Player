import Combine
import Foundation
import Libmpv
#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif
#if os(iOS) || os(tvOS)
import AVFoundation
#endif

// MARK: - Public model

enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case ended
    case failed(String)
}

enum DynamicRange: String {
    case sdr = "SDR"
    case hdr10 = "HDR10"
    case hlg = "HLG"
    case dolbyVision = "Dolby Vision"
}

struct VideoSignal: Equatable {
    var width = 0
    var height = 0
    var fps: Double = 0
    var gamma = ""
    var primaries = ""
    var colorMatrix = ""
    var dolbyVisionProfile = 0

    var dynamicRange: DynamicRange {
        if dolbyVisionProfile > 0 || colorMatrix.contains("dolbyvision") { return .dolbyVision }
        switch gamma {
        case "pq": return .hdr10
        case "hlg": return .hlg
        default: return .sdr
        }
    }

    var resolutionLabel: String {
        switch max(width, height) {
        case 3000...: return "4K"
        case 1800...: return "1080p"
        case 1200...: return "720p"
        case 1...: return "SD"
        default: return ""
        }
    }
}

struct MediaTrack: Identifiable, Hashable {
    enum Kind: String {
        case video, audio, sub
    }

    let id: Int
    let kind: Kind
    let title: String?
    let language: String?
    let codec: String?
    let channels: Int
    let dolbyVisionProfile: Int
    let isDefault: Bool
    let isExternal: Bool
    let isSelected: Bool

    var label: String {
        var parts: [String] = []
        if let language, !language.isEmpty { parts.append(Locale.current.localizedString(forLanguageCode: language) ?? language.uppercased()) }
        if let title, !title.isEmpty, title != language { parts.append(title) }
        if let codec { parts.append(Self.prettyCodec(codec)) }
        if kind == .audio, channels > 0 { parts.append(Self.channelLayout(channels)) }
        if isExternal { parts.append("Ngoài") }
        return parts.isEmpty ? "Track \(id)" : parts.joined(separator: " · ")
    }

    static func prettyCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "truehd", "mlp": return "TrueHD"
        case "dts": return "DTS"
        case "eac3": return "DD+"
        case "ac3": return "AC3"
        case "flac": return "FLAC"
        case "aac": return "AAC"
        case "opus": return "Opus"
        case "hevc": return "HEVC"
        case "h264": return "H.264"
        case "av1": return "AV1"
        case "subrip": return "SRT"
        case "ass", "ssa": return "ASS"
        case "webvtt": return "VTT"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        default: return codec.uppercased()
        }
    }

    static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }
}

struct AudioSignal: Equatable {
    var codec = ""
    var channels = 0
    var sampleRate = 0
    var outputChannels = 0
}

struct PlayerOptions {
    /// Signal the source colourspace (HDR10/HLG/DV-as-PQ) to the display instead of tone-mapping to SDR.
    var hdrPassthrough = true
    /// macOS only: bitstream AC3/E-AC3/DTS/DTS-HD/TrueHD to an HDMI/S-PDIF receiver (exclusive Core Audio).
    var audioPassthrough = false
    /// Preferred subtitle languages (mpv --slang).
    var subtitleLanguages = "vi,vie,en,eng"
    /// Forward demuxer cache (RAM) for high-bitrate remuxes over Wi-Fi 6 / LAN.
    var cacheMegabytes: Int

    static var standard: PlayerOptions {
        #if os(macOS)
        return PlayerOptions(cacheMegabytes: 1024)
        #else
        return PlayerOptions(cacheMegabytes: 400)
        #endif
    }
}

// MARK: - Engine

/// libmpv wrapper: vo=gpu-next on Vulkan (MoltenVK → Metal), VideoToolbox hardware decoding,
/// libplacebo tone-mapping (HDR10/HLG/Dolby Vision P5/P8 via libdovi), libass subtitles.
///
/// Threading: every libmpv call runs on `queue`; published state is updated on the main queue.
final class MPVPlayerEngine: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var video = VideoSignal()
    @Published private(set) var audio = AudioSignal()
    @Published private(set) var hardwareDecoder = ""
    @Published private(set) var videoCodec = ""
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var subtitleDelay: Double = 0
    @Published private(set) var nightMode = false
    @Published private(set) var hdrOutputActive = false

    let options: PlayerOptions

    private let queue = DispatchQueue(label: "xt.mpv.core", qos: .userInitiated)
    private var handle: OpaquePointer?          // queue only
    private var lastPublishedTime: Double = -1  // queue only
    private var isPaused = false                // queue only
    private var reachedEOF = false              // queue only

    private var attached = false                // main only
    private var pendingLoad: (location: String, start: Double?)?
    private var retainedLayer: MPVMetalLayer?
    private weak var hostView: MPVVideoView?
    private var notificationTokens: [NSObjectProtocol] = []
    #if os(tvOS)
    private let displayMatcher = DisplayModeMatcher()
    #endif

    init(options: PlayerOptions = .standard) {
        self.options = options
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
    }

    // MARK: Lifecycle

    /// Called by `PlayerSurface` once the Metal layer exists. mpv renders into it via `wid`.
    func attach(to view: MPVVideoView) {
        guard !attached else { return }
        attached = true
        hostView = view
        retainedLayer = view.metalLayer
        let wid = Int64(Int(bitPattern: Unmanaged.passUnretained(view.metalLayer).toOpaque()))
        let hdr = options.hdrPassthrough && Self.displaySupportsHDR(view)
        hdrOutputActive = hdr
        #if os(iOS) || os(tvOS)
        AudioSessionConfigurator.activateForMoviePlayback()
        #endif
        queue.async { self.createCore(wid: wid, hdr: hdr) }
        observeAppLifecycle()
        if let pending = pendingLoad {
            pendingLoad = nil
            load(pending.location, startAt: pending.start)
        }
    }

    /// Stops playback and destroys the mpv core. Safe to call more than once.
    func shutdown() {
        #if os(tvOS)
        displayMatcher.reset(window: hostView?.window)
        #endif
        #if os(iOS) || os(tvOS)
        AudioSessionConfigurator.deactivate()
        #endif
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        let layer = retainedLayer
        retainedLayer = nil
        queue.async {
            guard let handle = self.handle else { return }
            self.handle = nil
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            // The layer must outlive the VO thread that renders into it.
            DispatchQueue.main.async { _ = layer }
        }
    }

    // MARK: Commands

    func load(_ location: String, startAt start: Double? = nil) {
        guard attached else {
            pendingLoad = (location, start)
            return
        }
        state = .loading
        queue.async {
            var args = ["loadfile", location, "replace", "-1"]
            if let start, start > 0 { args.append("start=\(Int(start))") }
            self.command(args)
        }
    }

    func togglePause() { queue.async { self.command(["cycle", "pause"]) } }
    func play() { setProperty("pause", "no") }
    func pause() { setProperty("pause", "yes") }

    func seek(to seconds: Double) {
        queue.async { self.command(["seek", String(format: "%.3f", max(0, seconds)), "absolute"]) }
    }

    func seek(by seconds: Double) {
        queue.async { self.command(["seek", String(format: "%.3f", seconds), "relative"]) }
    }

    func selectAudioTrack(_ id: Int) { setProperty("aid", "\(id)") }

    /// nil disables subtitles.
    func selectSubtitleTrack(_ id: Int?) { setProperty("sid", id.map { "\($0)" } ?? "no") }

    func adjustSubtitleDelay(by delta: Double) {
        queue.async { self.command(["add", "sub-delay", String(format: "%.2f", delta)]) }
    }

    func resetSubtitleDelay() { setProperty("sub-delay", "0") }

    /// Night mode: dynamic range compression + loudness normalisation (FFmpeg dynaudnorm).
    func setNightMode(_ enabled: Bool) {
        nightMode = enabled
        setProperty("af", enabled ? "lavfi=[dynaudnorm=f=250:g=31:p=0.6:m=8]" : "")
    }

    // MARK: - mpv core

    private func createCore(wid: Int64, hdr: Bool) {
        guard let mpv = mpv_create() else {
            publish { $0.state = .failed("Không khởi tạo được libmpv") }
            return
        }
        #if DEBUG
        mpv_request_log_messages(mpv, "warn")
        #endif

        var windowID = wid
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &windowID)

        var settings: [(String, String)] = [
            // Video: Vulkan → MoltenVK → Metal, VideoToolbox decode, libplacebo rendering.
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("hwdec-codecs", "all"),
            ("video-rotate", "no"),
            ("target-colorspace-hint", hdr ? "yes" : "no"),
            ("target-colorspace-hint-mode", "source"),
            ("tone-mapping", "auto"),
            ("hdr-compute-peak", "auto"),
            // Playback / cache (Smart RAM caching for >100 Mbps remuxes).
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "\(options.cacheMegabytes)MiB"),
            ("demuxer-max-back-bytes", "\(max(64, options.cacheMegabytes / 4))MiB"),
            ("demuxer-readahead-secs", "60"),
            ("cache-pause-wait", "2"),
            ("network-timeout", "30"),
            ("user-agent", "XT-Player/0.1 (libmpv)"),
            // Subtitles: libass keeps .ass/.ssa styling & karaoke intact.
            ("slang", options.subtitleLanguages),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("sub-auto", "fuzzy"),
            ("sub-file-paths", "Subs:Subtitles:subs"),
            // Audio.
            ("audio-channels", "auto"),
            ("volume-max", "150"),
            // Embedded use: no built-in UI, scripts or key bindings.
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
        ]
        #if os(macOS)
        settings.append(("ao", "coreaudio"))
        settings.append(("input-media-keys", "yes"))
        if options.audioPassthrough {
            settings.append(("audio-spdif", "ac3,eac3,dts,dts-hd,truehd"))
            settings.append(("audio-exclusive", "yes"))
        }
        #else
        settings.append(("ao", "audiounit"))
        #endif
        for (name, value) in settings {
            let status = mpv_set_option_string(mpv, name, value)
            #if DEBUG
            if status < 0 { print("[mpv] option \(name)=\(value): \(String(cString: mpv_error_string(status)))") }
            #endif
            _ = status
        }

        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            publish { $0.state = .failed("libmpv không khởi động được") }
            return
        }

        let observed: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG),
            ("eof-reached", MPV_FORMAT_FLAG),
            ("demuxer-cache-duration", MPV_FORMAT_DOUBLE),
            ("track-list/count", MPV_FORMAT_INT64),
            ("aid", MPV_FORMAT_STRING),
            ("sid", MPV_FORMAT_STRING),
            ("sub-delay", MPV_FORMAT_DOUBLE),
            ("video-params/w", MPV_FORMAT_INT64),
            ("video-params/h", MPV_FORMAT_INT64),
            ("video-params/gamma", MPV_FORMAT_STRING),
            ("video-params/primaries", MPV_FORMAT_STRING),
            ("video-params/colormatrix", MPV_FORMAT_STRING),
            ("container-fps", MPV_FORMAT_DOUBLE),
            ("hwdec-current", MPV_FORMAT_STRING),
            ("audio-params/channel-count", MPV_FORMAT_INT64),
            ("audio-params/samplerate", MPV_FORMAT_INT64),
        ]
        for (name, format) in observed {
            mpv_observe_property(mpv, 0, name, format)
        }

        handle = mpv
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let engine = Unmanaged<MPVPlayerEngine>.fromOpaque(context).takeUnretainedValue()
            engine.queue.async { engine.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func drainEvents() {
        guard let mpv = handle else { return }
        while true {
            guard let event = mpv_wait_event(mpv, 0) else { return }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { return }
            switch id {
            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = event.pointee.data {
                    handleProperty(data.assumingMemoryBound(to: mpv_event_property.self).pointee, mpv: mpv)
                }
            case MPV_EVENT_START_FILE:
                reachedEOF = false
                lastPublishedTime = -1
                publish {
                    $0.state = .loading
                    $0.position = 0
                    $0.video = VideoSignal()
                }
            case MPV_EVENT_FILE_LOADED:
                refreshTracks(mpv)
                let paused = isPaused
                publish { $0.state = paused ? .paused : .playing }
            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data {
                    let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if end.reason == MPV_END_FILE_REASON_ERROR {
                        let message = String(cString: mpv_error_string(end.error))
                        publish { $0.state = .failed("Không phát được: \(message)") }
                    } else if end.reason == MPV_END_FILE_REASON_EOF {
                        publish { $0.state = .ended }
                    }
                }
            case MPV_EVENT_SHUTDOWN:
                return
            #if DEBUG
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data {
                    let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    print("[mpv/\(String(cString: msg.prefix))] \(String(cString: msg.text))", terminator: "")
                }
            #endif
            default:
                break
            }
        }
    }

    private func handleProperty(_ property: mpv_event_property, mpv: OpaquePointer) {
        let name = String(cString: property.name)
        let data = property.data
        let available = property.format != MPV_FORMAT_NONE && data != nil

        func double() -> Double { available ? data!.assumingMemoryBound(to: Double.self).pointee : 0 }
        func flag() -> Bool { available ? data!.assumingMemoryBound(to: Int32.self).pointee != 0 : false }
        func int() -> Int { available ? Int(data!.assumingMemoryBound(to: Int64.self).pointee) : 0 }
        func string() -> String {
            guard available, let cString = data!.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return "" }
            return String(cString: cString)
        }

        switch name {
        case "time-pos":
            let t = double()
            if abs(t - lastPublishedTime) >= 0.25 || isPaused {
                lastPublishedTime = t
                publish { $0.position = t }
            }
        case "duration":
            let d = double()
            publish { $0.duration = d }
        case "pause":
            isPaused = flag()
            let paused = isPaused, ended = reachedEOF
            publish {
                guard $0.state != .loading || !paused else { return }
                if case .failed = $0.state { return }
                $0.state = ended ? .ended : (paused ? .paused : .playing)
            }
        case "paused-for-cache":
            let b = flag()
            publish { $0.isBuffering = b }
        case "eof-reached":
            reachedEOF = flag()
            if reachedEOF { publish { $0.state = .ended } }
        case "demuxer-cache-duration":
            let s = double()
            publish { $0.bufferedSeconds = s }
        case "track-list/count", "aid", "sid":
            refreshTracks(mpv)
        case "sub-delay":
            let d = double()
            publish { $0.subtitleDelay = d }
        case "video-params/w":
            let v = int(); updateVideo { $0.width = v }
        case "video-params/h":
            let v = int(); updateVideo { $0.height = v }
        case "video-params/gamma":
            let v = string(); updateVideo { $0.gamma = v }
        case "video-params/primaries":
            let v = string(); updateVideo { $0.primaries = v }
        case "video-params/colormatrix":
            let v = string(); updateVideo { $0.colorMatrix = v }
        case "container-fps":
            let v = double(); updateVideo { $0.fps = v }
        case "hwdec-current":
            let v = string()
            publish { $0.hardwareDecoder = v }
        case "audio-params/channel-count":
            let v = int()
            publish { $0.audio.outputChannels = v }
        case "audio-params/samplerate":
            let v = int()
            publish { $0.audio.sampleRate = v }
        default:
            break
        }
    }

    private func updateVideo(_ change: @escaping (inout VideoSignal) -> Void) {
        publish { engine in
            var signal = engine.video
            change(&signal)
            guard signal != engine.video else { return }
            engine.video = signal
            engine.matchDisplayIfNeeded()
        }
    }

    /// Reads `track-list` entry by entry (scalar sub-properties keep this independent of node parsing).
    private func refreshTracks(_ mpv: OpaquePointer) {
        let count = getInt(mpv, "track-list/count")
        var audio: [MediaTrack] = []
        var subs: [MediaTrack] = []
        var selectedVideoCodec = ""
        var selectedAudio: MediaTrack?
        var dvProfile = 0
        for i in 0..<max(0, count) {
            let p = "track-list/\(i)/"
            guard let type = getString(mpv, p + "type"), let kind = MediaTrack.Kind(rawValue: type) else { continue }
            let track = MediaTrack(
                id: getInt(mpv, p + "id"),
                kind: kind,
                title: getString(mpv, p + "title"),
                language: getString(mpv, p + "lang"),
                codec: getString(mpv, p + "codec"),
                channels: getInt(mpv, p + "demux-channel-count"),
                dolbyVisionProfile: getInt(mpv, p + "dolby-vision-profile"),
                isDefault: getFlag(mpv, p + "default"),
                isExternal: getFlag(mpv, p + "external"),
                isSelected: getFlag(mpv, p + "selected")
            )
            switch kind {
            case .video:
                if track.isSelected {
                    selectedVideoCodec = track.codec.map(MediaTrack.prettyCodec) ?? ""
                    dvProfile = track.dolbyVisionProfile
                }
            case .audio:
                audio.append(track)
                if track.isSelected { selectedAudio = track }
            case .sub:
                subs.append(track)
            }
        }
        publish { engine in
            engine.audioTracks = audio
            engine.subtitleTracks = subs
            engine.videoCodec = selectedVideoCodec
            engine.audio.codec = selectedAudio?.codec.map(MediaTrack.prettyCodec) ?? ""
            engine.audio.channels = selectedAudio?.channels ?? 0
            if engine.video.dolbyVisionProfile != dvProfile {
                engine.video.dolbyVisionProfile = dvProfile
            }
        }
    }

    // MARK: - Display mode (tvOS Match Content)

    private func matchDisplayIfNeeded() {
        #if os(tvOS)
        guard video.width > 0, video.height > 0, !video.gamma.isEmpty, video.fps > 0 else { return }
        let window = hostView?.window
        if displayMatcher.match(video, window: window) {
            // Hold playback while the TV re-syncs so the first seconds are not lost to a black screen.
            pause()
            waitForDisplaySwitch(window: window, remaining: 24)
        }
        #endif
    }

    #if os(tvOS)
    private func waitForDisplaySwitch(window: UIWindow?, remaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.displayMatcher.isSwitching(window: window), remaining > 0 {
                self.waitForDisplaySwitch(window: window, remaining: remaining - 1)
            } else {
                self.play()
            }
        }
    }
    #endif

    // MARK: - App lifecycle

    private func observeAppLifecycle() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            // Releasing the video output avoids a black surface when returning to the foreground.
            self?.pause()
            self?.setProperty("vid", "no")
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setProperty("vid", "auto")
        })
        #endif
    }

    // MARK: - Helpers

    private static func displaySupportsHDR(_ view: MPVVideoView) -> Bool {
        #if os(iOS) || os(tvOS)
        return AVPlayer.eligibleForHDRPlayback
        #else
        let screen = view.window?.screen ?? NSScreen.main
        return (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        #endif
    }

    private func publish(_ change: @escaping (MPVPlayerEngine) -> Void) {
        DispatchQueue.main.async { change(self) }
    }

    private func setProperty(_ name: String, _ value: String) {
        queue.async {
            guard let mpv = self.handle else { return }
            mpv_set_property_string(mpv, name, value)
        }
    }

    /// Runs an mpv command. Must be called on `queue`.
    private func command(_ args: [String]) {
        guard let mpv = handle else { return }
        var cArgs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cArgs.append(nil)
        defer { cArgs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        let status = mpv_command(mpv, &cArgs)
        #if DEBUG
        if status < 0 { print("[mpv] command \(args): \(String(cString: mpv_error_string(status)))") }
        #endif
        _ = status
    }

    private func getString(_ mpv: OpaquePointer, _ name: String) -> String? {
        guard let cString = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cString) }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }

    private func getInt(_ mpv: OpaquePointer, _ name: String) -> Int {
        var value: Int64 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value)
        return Int(value)
    }

    private func getFlag(_ mpv: OpaquePointer, _ name: String) -> Bool {
        var value: Int32 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value)
        return value != 0
    }
}
