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
    /// Display size (sample aspect ratio applied), e.g. 854×480 for an anamorphic DVD.
    var displayWidth = 0
    var displayHeight = 0
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

    /// Width / height of the picture as shown; 0 until mpv knows it.
    var displayAspect: Double {
        if displayWidth > 0, displayHeight > 0 { return Double(displayWidth) / Double(displayHeight) }
        if width > 0, height > 0 { return Double(width) / Double(height) }
        return 0
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
        let lower = codec.lowercased()
        if lower.hasPrefix("pcm_") { return "PCM" }
        if lower.hasPrefix("dsd_") { return "DSD" }
        switch lower {
        case "truehd": return "TrueHD"
        case "mlp": return "MLP"
        case "dst": return "DSD (DST)"
        case "wavpack": return "WavPack"
        case "alac": return "ALAC"
        case "ape": return "APE"
        case "tta": return "TTA"
        case "tak": return "TAK"
        case "mpc7", "mpc8": return "Musepack"
        case "vorbis": return "Vorbis"
        case "mp3", "mp3float": return "MP3"
        case "vvc": return "H.266"
        case "vp9": return "VP9"
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
    /// Rate mpv hands the audio output (after its own resampling, if any).
    var outputSampleRate = 0
    /// Rate the output device itself runs at (the system mixer resamples to it when it differs).
    var deviceSampleRate = 0.0
    /// Decoded sample format ("s32" for 24-bit FLAC / TrueHD / DTS-HD MA, "floatp" for lossy codecs).
    var sampleFormat = ""

    /// Above CD / DVD rate (88.2 kHz and up).
    var isHighResolution: Bool { sampleRate > 48_000 }

    /// Reaches the device at the file's own rate: no resampling by mpv or by the system mixer.
    var isNativeRate: Bool {
        sampleRate > 0 && outputSampleRate == sampleRate && (deviceSampleRate <= 0 || abs(deviceSampleRate - Double(sampleRate)) < 1)
    }
}

struct PlayerOptions {
    /// Signal the source colourspace (HDR10/HLG/DV-as-PQ) to the display instead of tone-mapping to SDR.
    var hdrPassthrough = true
    /// macOS only: bitstream AC3/E-AC3/DTS/DTS-HD/TrueHD to an HDMI/S-PDIF receiver (exclusive Core Audio).
    var audioPassthrough = false
    /// Preferred subtitle languages (mpv --slang).
    var subtitleLanguages = "vi,vie,en,eng"
    /// Preferred audio languages (mpv --alang); empty = the file's default track.
    var audioLanguages = ""
    /// Forward demuxer cache (RAM) for high-bitrate remuxes over Wi-Fi 6 / LAN.
    var cacheMegabytes: Int
    /// "auto" deinterlaces only frames FFmpeg flags as interlaced (DVD/broadcast rips).
    var deinterlace = "auto"
    /// Text subtitle appearance (ASS/SSA keep their own styling).
    var subtitleScale = 1.0
    var subtitlePosition = 100
    var subtitleBackground = false
    /// VideoToolbox decoding; mpv falls back to software by itself for codecs the chip cannot decode.
    var hardwareDecoding = true
    var pictureQuality = PictureQuality.platformDefault
    /// Display-synchronised playback with frame blending: no 24p judder on a 60 Hz screen.
    var motionSmoothing = false
    /// macOS: switch the output device to the file's sample rate instead of letting the system mixer resample.
    var matchSampleRate = false
    var nightMode = false
    var dialogBoost = false

    static var standard: PlayerOptions {
        #if os(macOS)
        return PlayerOptions(cacheMegabytes: 1024)
        #else
        return PlayerOptions(cacheMegabytes: 400)
        #endif
    }

    /// Current values from Settings.
    static func fromSettings() -> PlayerOptions {
        let d = UserDefaults.standard
        var o = PlayerOptions.standard
        o.hdrPassthrough = d.bool(forKey: AppSettings.hdrPassthrough)
        o.audioPassthrough = d.bool(forKey: AppSettings.audioPassthrough)
        o.subtitleLanguages = d.string(forKey: AppSettings.subtitleLanguages) ?? o.subtitleLanguages
        o.audioLanguages = d.string(forKey: AppSettings.audioLanguages) ?? ""
        let cache = d.integer(forKey: AppSettings.cacheMegabytes)
        if cache >= 64 { o.cacheMegabytes = cache }
        o.deinterlace = d.string(forKey: AppSettings.deinterlace) ?? "auto"
        let scale = d.double(forKey: AppSettings.subtitleScale)
        if scale > 0.2 { o.subtitleScale = scale }
        let position = d.integer(forKey: AppSettings.subtitlePosition)
        if position > 0 { o.subtitlePosition = position }
        o.subtitleBackground = d.bool(forKey: AppSettings.subtitleBackground)
        o.hardwareDecoding = d.object(forKey: AppSettings.hardwareDecoding) as? Bool ?? true
        o.pictureQuality = PictureQuality(rawValue: d.string(forKey: AppSettings.pictureQuality) ?? "") ?? .platformDefault
        o.motionSmoothing = d.bool(forKey: AppSettings.motionSmoothing)
        o.matchSampleRate = d.bool(forKey: AppSettings.matchSampleRate)
        o.nightMode = d.bool(forKey: AppSettings.nightMode)
        o.dialogBoost = d.bool(forKey: AppSettings.dialogBoost)
        return o
    }
}

/// How hard libplacebo works on the picture: scaling, debanding and HDR tone-mapping.
enum PictureQuality: String, CaseIterable, Identifiable {
    case balanced, high, max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: return "Cân bằng"
        case .high: return "Cao"
        case .max: return "Tối đa"
        }
    }

    var detail: String {
        switch self {
        case .balanced: return "Nhẹ máy, tiết kiệm pin"
        case .high: return "Phóng to EWA Lanczos, khử dải màu, tone-map HDR chi tiết"
        case .max: return "Phóng to Lanczos 4 nhánh cho cả màu — cần GPU khoẻ"
        }
    }

    /// Renderer options a preset may change; the rest keep libmpv's defaults.
    static let keys = ["scale", "cscale", "deband", "hdr-peak-percentile", "hdr-contrast-recovery"]

    /// mpv's built-in "high-quality" profile plus debanding (8-bit web and streaming encodes band in skies
    /// and dark scenes); "max" also upsamples chroma with the EWA scaler.
    var values: [String: String] {
        switch self {
        case .balanced:
            return [:]
        case .high:
            return ["scale": "ewa_lanczossharp", "deband": "yes", "hdr-peak-percentile": "99.995", "hdr-contrast-recovery": "0.30"]
        case .max:
            return ["scale": "ewa_lanczos4sharpest", "cscale": "ewa_lanczossharp", "deband": "yes",
                    "hdr-peak-percentile": "99.995", "hdr-contrast-recovery": "0.30"]
        }
    }

    /// Apple silicon Macs have GPU to spare; iPhone, iPad and Apple TV keep the battery and the 4K frame rate.
    static var platformDefault: PictureQuality {
        #if os(macOS)
        return .high
        #else
        return .balanced
        #endif
    }
}

/// Night mode and dialogue boost as an FFmpeg filter chain (filters enabled in XT-Player's FFmpeg build,
/// see Packages/MPVKit). Night mode also turns on the AC-3 / E-AC-3 decoder's own DRC metadata.
enum AudioEnhancement {
    static func filter(night: Bool, dialog: Bool, source: Int, output: Int) -> String {
        guard night || dialog, source > 0, output > 0 else { return "" }
        var chain: [String] = []
        if source <= 2 {
            // Stereo has no centre channel: dialoguenhance pulls the voice band out of what both sides share.
            if dialog, source == 2 { chain.append("dialoguenhance=original=1:enhance=1.5:voice=3") }
        } else if output <= 2 {
            // Speakers / headphones: a dialogue-first downmix instead of the standard -3 dB centre.
            let centre = dialog ? 1.2 : 1.0, surround = dialog ? 0.35 : 0.5
            chain.append(String(format: "aresample=out_chlayout=stereo:clev=%.2f:slev=%.2f:lfe_mix_level=0", centre, surround))
        } else {
            // Receiver / TV: keep the layout, lower everything around the centre channel.
            let wide = source >= 8 && output >= 8
            let side = dialog ? 0.6 : 0.75, front = dialog ? 0.7 : 1.0
            var gains = [
                String(format: "FL=%.2f*FL", front), String(format: "FR=%.2f*FR", front), "FC=FC",
                String(format: "LFE=%.2f*LFE", night ? 0.5 : 0.7),
                String(format: "BL=%.2f*BL", side), String(format: "BR=%.2f*BR", side),
            ]
            if wide { gains += [String(format: "SL=%.2f*SL", side), String(format: "SR=%.2f*SR", side)] }
            let layout = wide ? "7.1" : "5.1"
            chain.append("aresample=out_chlayout=\(layout)")
            chain.append("pan=\(layout)|\(gains.joined(separator: "|"))")
        }
        // Night: raise quiet passages and hold back explosions, frame by frame (peaks capped at 0.6).
        if night { chain.append("dynaudnorm=f=250:g=31:p=0.6:m=8") }
        return chain.isEmpty ? "" : "lavfi=[\(chain.joined(separator: ","))]"
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: String          // mpv device name ("auto", "coreaudio/…", "avfoundation/…")
    let description: String
}

struct Chapter: Identifiable, Hashable {
    let id: Int
    let title: String
    let time: Double
}

enum VideoFit: String, CaseIterable, Identifiable {
    case fit, fill, stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "Vừa khung (giữ tỉ lệ)"
        case .fill: return "Lấp đầy (cắt viền)"
        case .stretch: return "Kéo giãn"
        }
    }
}

/// Recent mpv warnings/errors, readable from the player's Info panel (and copyable for bug reports).
final class MPVLogBuffer: @unchecked Sendable {
    static let shared = MPVLogBuffer()
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 300

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
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
    /// 0…100 while mpv refills the cache after an underrun.
    @Published private(set) var bufferingProgress = 0
    /// Bytes per second mpv reads from an HTTP(S) source (mpv `cache-speed`).
    @Published private(set) var readSpeed: Double = 0
    /// The current file comes through the app's xtsmb:// bridge (its traffic is in `StreamTrafficMeter`).
    @Published private(set) var readsThroughBridge = false
    /// What `load` was given (path or URL), for subtitle search by file hash.
    private(set) var currentLocation = ""
    @Published private(set) var video = VideoSignal()
    @Published private(set) var audio = AudioSignal()
    @Published private(set) var hardwareDecoder = ""
    @Published private(set) var videoCodec = ""
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var subtitleDelay: Double = 0
    @Published private(set) var nightMode = false
    @Published private(set) var dialogBoost = false
    @Published private(set) var hardwareDecoding = true
    @Published private(set) var pictureQuality = PictureQuality.platformDefault
    @Published private(set) var motionSmoothing = false
    /// Frames dropped because decoding or rendering could not keep up (a hint to lower the picture quality).
    @Published private(set) var droppedFrames = 0
    @Published private(set) var hdrOutputActive = false
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var currentChapter = -1
    @Published private(set) var speed: Double = 1
    @Published private(set) var audioDelay: Double = 0
    @Published private(set) var subtitleScale: Double = 1
    @Published private(set) var videoFit: VideoFit = .fit
    /// mpv audio output actually in use ("coreaudio", "audiounit", "avfoundation"), empty = none.
    @Published private(set) var audioOutput = ""

    /// Bitstreaming to a receiver: the volume is the receiver's, not the app's or the system's.
    var isBitstreaming: Bool { audioOutput == "coreaudio_exclusive" }

    /// mpv bitstreams through libavformat's spdif muxer (enabled in XT-Player's FFmpeg build; upstream MPVKit
    /// leaves it out, and ad_spdif then fails with "libavformat spdif initialization failed").
    static let bitstreamSupported = true
    @Published private(set) var videoBitrate: Double = 0
    @Published private(set) var audioBitrate: Double = 0
    @Published private(set) var volume: Double = 100
    @Published private(set) var isMuted = false
    @Published private(set) var audioDevices: [AudioDevice] = []
    @Published private(set) var audioDevice = "auto"

    let options: PlayerOptions

    private let queue = DispatchQueue(label: "xt.mpv.core", qos: .userInitiated)
    private var handle: OpaquePointer?          // queue only
    private var lastPublishedTime: Double = -1  // queue only
    private var isPaused = false                // queue only
    private var reachedEOF = false              // queue only
    private var pendingSubtitles: [String] = [] // queue only: sidecar subtitles for the file being loaded
    private var rendererDefaults: [String: String] = [:] // queue only: libmpv's own values of PictureQuality.keys
    private var wantsNightMode = false          // queue only
    private var wantsDialogBoost = false        // queue only
    private var sourceChannels = 0              // queue only
    private var outputChannels = 0              // queue only
    private var appliedAudioFilter = ""         // queue only
    private var appliedAC3DRC = "0"             // queue only
    private var decoderDrops = 0                // queue only
    private var outputDrops = 0                 // queue only

    private var attached = false                // main only
    private var pendingLoad: (location: String, start: Double?, subtitles: [String])?
    private var retainedLayer: MPVMetalLayer?
    private weak var hostView: MPVVideoView?
    private var notificationTokens: [NSObjectProtocol] = []
    #if os(tvOS)
    private let displayMatcher = DisplayModeMatcher()
    #endif

    init(options: PlayerOptions = .fromSettings()) {
        self.options = options
        nightMode = options.nightMode
        dialogBoost = options.dialogBoost
        hardwareDecoding = options.hardwareDecoding
        pictureQuality = options.pictureQuality
        motionSmoothing = options.motionSmoothing
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
        let refreshRate = Self.displayRefreshRate(view)
        #if os(iOS) || os(tvOS)
        AudioSessionConfigurator.activateForMoviePlayback()
        #endif
        queue.async { self.createCore(wid: wid, hdr: hdr, refreshRate: refreshRate) }
        observeAppLifecycle()
        if let pending = pendingLoad {
            pendingLoad = nil
            load(pending.location, startAt: pending.start, externalSubtitles: pending.subtitles)
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

    /// Loads a file (replacing the current one). `externalSubtitles` are sidecar files (local paths or
    /// URLs, including xtsmb://) added once the file is open.
    func load(_ location: String, startAt start: Double? = nil, externalSubtitles: [String] = []) {
        guard attached else {
            pendingLoad = (location, start, externalSubtitles)
            return
        }
        state = .loading
        position = 0
        duration = 0
        chapters = []
        readsThroughBridge = location.hasPrefix("xtsmb:")
        currentLocation = location
        queue.async {
            self.pendingSubtitles = externalSubtitles
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

    /// Loads a subtitle file (e.g. downloaded from OpenSubtitles) and shows it.
    func addSubtitle(_ path: String) {
        queue.async { self.command(["sub-add", path, "select"]) }
    }

    /// nil disables subtitles.
    func selectSubtitleTrack(_ id: Int?) { setProperty("sid", id.map { "\($0)" } ?? "no") }

    func adjustSubtitleDelay(by delta: Double) {
        queue.async { self.command(["add", "sub-delay", String(format: "%.2f", delta)]) }
    }

    func resetSubtitleDelay() { setProperty("sub-delay", "0") }

    func setSpeed(_ value: Double) { setProperty("speed", String(format: "%.2f", value)) }

    func adjustAudioDelay(by delta: Double) {
        queue.async { self.command(["add", "audio-delay", String(format: "%.3f", delta)]) }
    }

    func resetAudioDelay() { setProperty("audio-delay", "0") }

    func adjustSubtitleScale(by delta: Double) {
        let target = min(3, max(0.4, subtitleScale + delta))
        setProperty("sub-scale", String(format: "%.2f", target))
    }

    /// Fit / Fill / Stretch are applied by `MPVVideoView` (a compositor transform of the picture), so mpv
    /// keeps rendering the whole picture and no swapchain is rebuilt.
    func setVideoFit(_ fit: VideoFit) {
        videoFit = fit
    }

    func selectChapter(_ index: Int) { setProperty("chapter", "\(index)") }

    /// 0…150 (mpv volume-max); unmutes when raised.
    func setVolume(_ value: Double) {
        let clamped = min(150, max(0, value))
        volume = clamped
        setProperty("volume", String(format: "%.0f", clamped))
        if clamped > 0, isMuted { setProperty("mute", "no") }
    }

    func toggleMute() { setProperty("mute", isMuted ? "no" : "yes") }

    /// Output device ("auto" = system default). mpv reopens the audio output on change.
    func selectAudioDevice(_ name: String) {
        audioDevice = name
        setProperty("audio-device", name)
    }

    /// iPhone / iPad / Apple TV: ask the audio session for the file's sample rate. A USB or Lightning DAC (and
    /// a receiver taking 44.1 kHz) then plays 44.1 / 88.2 / 96 / 192 kHz natively instead of everything being
    /// resampled to 48 kHz; outputs with a fixed rate keep theirs. mpv reopens its output at the new rate.
    fileprivate func followSourceSampleRate(_ rate: Int) {
        #if os(iOS) || os(tvOS)
        guard rate > 0 else { return }
        let session = AVAudioSession.sharedInstance()
        guard abs(session.sampleRate - Double(rate)) >= 1 else { return }
        try? session.setPreferredSampleRate(Double(rate))
        if abs(session.sampleRate - Double(rate)) < 1 {
            queue.async { self.command(["ao-reload"]) }
        }
        #endif
    }

    func refreshAudioDevices() {
        queue.async {
            guard let mpv = self.handle else { return }
            self.refreshAudioDevices(mpv)
        }
    }

    func skipChapter(_ step: Int) {
        queue.async { self.command(["add", "chapter", "\(step)"]) }
    }

    /// Night mode: the Dolby decoder's dynamic range compression, less LFE and surround.
    func setNightMode(_ enabled: Bool) {
        nightMode = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettings.nightMode)
        queue.async {
            self.wantsNightMode = enabled
            if let mpv = self.handle { self.applyAudioEnhancements(mpv) }
        }
    }

    /// Dialogue boost: centre channel (or the stereo mid) up against everything else.
    func setDialogBoost(_ enabled: Bool) {
        dialogBoost = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettings.dialogBoost)
        queue.async {
            self.wantsDialogBoost = enabled
            if let mpv = self.handle { self.applyAudioEnhancements(mpv) }
        }
    }

    /// VideoToolbox on / off for the file that is playing (mpv re-creates the decoder) and the next ones.
    func setHardwareDecoding(_ enabled: Bool) {
        hardwareDecoding = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettings.hardwareDecoding)
        setProperty("hwdec", enabled ? "videotoolbox" : "no")
    }

    func setPictureQuality(_ quality: PictureQuality) {
        pictureQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: AppSettings.pictureQuality)
        queue.async {
            if let mpv = self.handle { self.applyPictureQuality(quality, mpv) }
        }
    }

    func setMotionSmoothing(_ enabled: Bool) {
        motionSmoothing = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettings.motionSmoothing)
        queue.async {
            guard let mpv = self.handle else { return }
            for (name, value) in Self.motionOptions(enabled) { mpv_set_property_string(mpv, name, value) }
        }
    }

    /// Display-resample times every frame to the screen's refresh and re-times audio by the tiny difference;
    /// "oversample" blends only the frame that straddles a refresh, so motion is even without the soap-opera
    /// look of motion interpolation.
    private static func motionOptions(_ enabled: Bool) -> [(String, String)] {
        enabled ? [("video-sync", "display-resample"), ("interpolation", "yes"), ("tscale", "oversample")]
                : [("video-sync", "audio"), ("interpolation", "no")]
    }

    private func applyPictureQuality(_ quality: PictureQuality, _ mpv: OpaquePointer) {
        let values = quality.values
        for key in PictureQuality.keys {
            guard let value = values[key] ?? rendererDefaults[key], !value.isEmpty else { continue }
            let status = mpv_set_property_string(mpv, key, value)
            if status < 0 {
                MPVLogBuffer.shared.append("[xt] \(key)=\(value): \(String(cString: mpv_error_string(status)))")
            }
        }
    }

    /// Rebuilds the audio filter chain for the current source / output layout. Must be called on `queue`.
    private func applyAudioEnhancements(_ mpv: OpaquePointer) {
        let drc = wantsNightMode ? "1" : "0"
        if drc != appliedAC3DRC {
            appliedAC3DRC = drc
            mpv_set_property_string(mpv, "ad-lavc-ac3drc", drc)
        }
        let active = wantsNightMode || wantsDialogBoost
        // While the layout is unknown (between files) the current chain stays; off always clears it.
        guard !active || (sourceChannels > 0 && outputChannels > 0) else { return }
        let filter = AudioEnhancement.filter(night: wantsNightMode, dialog: wantsDialogBoost, source: sourceChannels, output: outputChannels)
        guard filter != appliedAudioFilter else { return }
        appliedAudioFilter = filter
        let status = mpv_set_property_string(mpv, "af", filter)
        if status < 0 {
            MPVLogBuffer.shared.append("[xt] af=\(filter): \(String(cString: mpv_error_string(status)))")
        }
    }

    // MARK: - mpv core

    private func createCore(wid: Int64, hdr: Bool, refreshRate: Double) {
        guard let mpv = mpv_create() else {
            publish { $0.state = .failed("Không khởi tạo được libmpv") }
            return
        }
        // Info-level log lines (AO/VO selection, warnings, errors) are always kept for the Info panel.
        mpv_request_log_messages(mpv, "info")

        var windowID = wid
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &windowID)

        var settings: [(String, String)] = [
            // Video: Vulkan → MoltenVK → Metal, VideoToolbox decode, libplacebo rendering.
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", options.hardwareDecoding ? "videotoolbox" : "no"),
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
            // After an underrun, refill several seconds before resuming instead of stuttering every 2 s;
            // also buffer before the first frame so playback does not stall right after it starts.
            ("cache-pause-wait", "4"),
            ("cache-pause-initial", "yes"),
            ("demuxer-seekable-cache", "yes"),
            // WebDAV/HTTP: keep the connection across seeks and reconnect after a dropped connection.
            ("stream-lavf-o", "reconnect=1,reconnect_on_network_error=1,reconnect_delay_max=5,multiple_requests=1"),
            ("network-timeout", "30"),
            ("user-agent", "XT-Player/0.1 (libmpv)"),
            // Subtitles: libass keeps .ass/.ssa styling & karaoke intact.
            ("slang", options.subtitleLanguages),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("sub-auto", "fuzzy"),
            ("sub-file-paths", "Subs:Subtitles:subs"),
            ("sub-scale", String(format: "%.2f", options.subtitleScale)),
            ("sub-pos", "\(options.subtitlePosition)"),
            ("sub-border-style", options.subtitleBackground ? "background-box" : "outline-and-shadow"),
            ("sub-back-color", options.subtitleBackground ? "#99000000" : "#80000000"),
            // Keep subtitles inside the picture: the surface's own black bars are cropped by MPVVideoView.
            ("sub-use-margins", "no"),
            ("deinterlace", options.deinterlace),
            // Audio.
            ("volume-max", "150"),
            // Embedded use: no built-in UI, scripts or key bindings.
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("osd-bar", "no"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
        ]
        if !options.audioLanguages.isEmpty { settings.append(("alang", options.audioLanguages)) }
        // When the output cannot run at the file's rate, resample with a longer filter than libswresample's
        // default (32 taps, 2^12 phases): less aliasing and passband ripple for hi-res sources.
        settings.append(("audio-resample-filter-size", "32"))
        settings.append(("audio-resample-phase-shift", "12"))
        // The embedded Metal surface gives mpv no refresh rate; display-resample needs it.
        if refreshRate > 0 { settings.append(("display-fps-override", String(format: "%.3f", refreshRate))) }
        if options.motionSmoothing { settings += Self.motionOptions(true) }
        wantsNightMode = options.nightMode
        wantsDialogBoost = options.dialogBoost
        appliedAC3DRC = options.nightMode ? "1" : "0"
        settings.append(("ad-lavc-ac3drc", appliedAC3DRC))
        #if os(macOS)
        // Fallback chain (trailing comma = then mpv's own auto-probe) so a failing output never means silence.
        settings.append(("ao", "coreaudio,avfoundation,"))
        // The system mixer's layout: stereo speakers get a proper downmix, multichannel devices get more.
        settings.append(("audio-channels", "auto-safe"))
        if options.audioPassthrough, Self.bitstreamSupported {
            // No audio-exclusive: mpv's CoreAudio output takes exclusive (hog) mode by itself only while it
            // bitstreams, and outputs without a digital format (built-in speakers, headphones) fall back to
            // decoded PCM on the shared mixer, so the system volume keeps working for everything else.
            settings.append(("audio-spdif", "ac3,eac3,dts,dts-hd,truehd"))
        }
        if options.matchSampleRate {
            // Bit-perfect sample rate: 44.1 kHz music and 48 / 96 kHz films reach a DAC without resampling.
            settings.append(("coreaudio-change-physical-format", "yes"))
        }
        #elseif os(tvOS)
        settings.append(("ao", "audiounit,avfoundation,"))
        // HDMI: hand the receiver the full 5.1 / 7.1 layout as multichannel LPCM.
        settings.append(("audio-channels", "auto"))
        #else
        settings.append(("ao", "audiounit,avfoundation,"))
        settings.append(("audio-channels", "auto-safe"))
        #endif
        for (name, value) in settings {
            let status = mpv_set_option_string(mpv, name, value)
            if status < 0 {
                MPVLogBuffer.shared.append("[xt] option \(name)=\(value): \(String(cString: mpv_error_string(status)))")
            }
        }

        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            publish { $0.state = .failed("libmpv không khởi động được") }
            return
        }

        MPVStreamProtocols.register(on: mpv)

        for key in PictureQuality.keys { rendererDefaults[key] = getString(mpv, key) ?? "" }
        applyPictureQuality(options.pictureQuality, mpv)

        let observed: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG),
            ("eof-reached", MPV_FORMAT_FLAG),
            ("demuxer-cache-duration", MPV_FORMAT_DOUBLE),
            ("cache-buffering-state", MPV_FORMAT_INT64),
            ("cache-speed", MPV_FORMAT_INT64),
            ("track-list/count", MPV_FORMAT_INT64),
            ("aid", MPV_FORMAT_STRING),
            ("sid", MPV_FORMAT_STRING),
            ("sub-delay", MPV_FORMAT_DOUBLE),
            ("video-params/w", MPV_FORMAT_INT64),
            ("video-params/h", MPV_FORMAT_INT64),
            ("video-params/dw", MPV_FORMAT_INT64),
            ("video-params/dh", MPV_FORMAT_INT64),
            ("video-params/gamma", MPV_FORMAT_STRING),
            ("video-params/primaries", MPV_FORMAT_STRING),
            ("video-params/colormatrix", MPV_FORMAT_STRING),
            ("container-fps", MPV_FORMAT_DOUBLE),
            ("hwdec-current", MPV_FORMAT_STRING),
            ("current-ao", MPV_FORMAT_STRING),
            ("video-bitrate", MPV_FORMAT_DOUBLE),
            ("audio-bitrate", MPV_FORMAT_DOUBLE),
            ("audio-params/channel-count", MPV_FORMAT_INT64),
            ("audio-out-params/channel-count", MPV_FORMAT_INT64),
            ("audio-out-params/samplerate", MPV_FORMAT_INT64),
            ("audio-params/format", MPV_FORMAT_STRING),
            ("frame-drop-count", MPV_FORMAT_INT64),
            ("vo-drop-frame-count", MPV_FORMAT_INT64),
            ("audio-params/samplerate", MPV_FORMAT_INT64),
            ("chapter-list/count", MPV_FORMAT_INT64),
            ("chapter", MPV_FORMAT_INT64),
            ("speed", MPV_FORMAT_DOUBLE),
            ("audio-delay", MPV_FORMAT_DOUBLE),
            ("sub-scale", MPV_FORMAT_DOUBLE),
            ("volume", MPV_FORMAT_DOUBLE),
            ("mute", MPV_FORMAT_FLAG),
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
                for subtitle in pendingSubtitles {
                    command(["sub-add", subtitle, "auto"])
                }
                pendingSubtitles = []
                refreshTracks(mpv)
                refreshChapters(mpv)
                refreshAudioDevices(mpv)
                scheduleAudioCheck()
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
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data {
                    let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let line = "[\(String(cString: msg.level))] \(String(cString: msg.prefix)): \(String(cString: msg.text))"
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    MPVLogBuffer.shared.append(line)
                    #if DEBUG
                    print("[mpv] \(line)")
                    #endif
                }
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
        case "cache-buffering-state":
            let v = int()
            publish { $0.bufferingProgress = v }
        case "cache-speed":
            let v = Double(int())
            publish { $0.readSpeed = v }
        case "track-list/count", "aid", "sid":
            refreshTracks(mpv)
        case "sub-delay":
            let d = double()
            publish { $0.subtitleDelay = d }
        case "video-params/w":
            let v = int(); updateVideo { $0.width = v }
        case "video-params/h":
            let v = int(); updateVideo { $0.height = v }
        case "video-params/dw":
            let v = int(); updateVideo { $0.displayWidth = v }
        case "video-params/dh":
            let v = int(); updateVideo { $0.displayHeight = v }
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
        case "current-ao":
            let v = string()
            publish { $0.audioOutput = v }
        case "video-bitrate":
            let v = double()
            publish { $0.videoBitrate = v }
        case "audio-bitrate":
            let v = double()
            publish { $0.audioBitrate = v }
        case "audio-params/channel-count":
            sourceChannels = int()
            applyAudioEnhancements(mpv)
        case "audio-out-params/channel-count":
            outputChannels = int()
            let v = outputChannels
            publish { $0.audio.outputChannels = v }
            applyAudioEnhancements(mpv)
        case "frame-drop-count", "vo-drop-frame-count":
            if name == "frame-drop-count" { decoderDrops = int() } else { outputDrops = int() }
            let v = decoderDrops + outputDrops
            publish { $0.droppedFrames = v }
        case "audio-params/samplerate":
            let v = int()
            publish {
                $0.audio.sampleRate = v
                $0.followSourceSampleRate(v)
            }
        case "audio-out-params/samplerate":
            let v = int()
            publish {
                $0.audio.outputSampleRate = v
                $0.audio.deviceSampleRate = AudioHardware.sampleRate(device: $0.audioDevice)
            }
        case "audio-params/format":
            let v = string()
            publish { $0.audio.sampleFormat = v }
        case "chapter-list/count":
            refreshChapters(mpv)
        case "chapter":
            let v = available ? int() : -1
            publish { $0.currentChapter = v }
        case "speed":
            let v = double()
            publish { $0.speed = v }
        case "volume":
            let v = double()
            publish { $0.volume = v }
        case "mute":
            let v = flag()
            publish { $0.isMuted = v }
        case "audio-delay":
            let v = double()
            publish { $0.audioDelay = v }
        case "sub-scale":
            let v = double()
            publish { $0.subtitleScale = v }
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

    /// If the file has audio but no output opened (device busy, unsupported layout…), switch to the
    /// AVFoundation output and reload instead of playing silently. Runs on `queue`.
    private var audioRecoveryTried = false

    private func scheduleAudioCheck() {
        audioRecoveryTried = false
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.checkAudioOutput() }
    }

    private func checkAudioOutput() {
        guard let mpv = handle, !audioRecoveryTried else { return }
        let hasAudio = (0..<max(0, getInt(mpv, "track-list/count"))).contains { getString(mpv, "track-list/\($0)/type") == "audio" }
        let aid = getString(mpv, "aid") ?? "no"
        guard hasAudio, aid != "no", (getString(mpv, "current-ao") ?? "").isEmpty else { return }
        audioRecoveryTried = true
        MPVLogBuffer.shared.append("[xt] no audio output opened — retrying with avfoundation")
        mpv_set_property_string(mpv, "ao", "avfoundation,coreaudio,audiounit,")
        command(["ao-reload"])
    }

    private func refreshAudioDevices(_ mpv: OpaquePointer) {
        var list: [AudioDevice] = []
        let current = getString(mpv, "audio-device") ?? "auto"
        for i in 0..<max(0, getInt(mpv, "audio-device-list/count")) {
            guard let name = getString(mpv, "audio-device-list/\(i)/name") else { continue }
            let description = name == "auto" ? "Mặc định hệ thống" : (getString(mpv, "audio-device-list/\(i)/description") ?? name)
            // Each output lists every device (coreaudio/…, avfoundation/…): show a device once, keeping
            // the entry in use, else the first (CoreAudio comes first in the "ao" chain).
            if let index = list.firstIndex(where: { $0.description == description }) {
                if name == current { list[index] = AudioDevice(id: name, description: description) }
                continue
            }
            list.append(AudioDevice(id: name, description: description))
        }
        publish {
            $0.audioDevices = list
            $0.audioDevice = current
        }
    }

    private func refreshChapters(_ mpv: OpaquePointer) {
        let count = getInt(mpv, "chapter-list/count")
        var list: [Chapter] = []
        for i in 0..<max(0, count) {
            var time = Double()
            mpv_get_property(mpv, "chapter-list/\(i)/time", MPV_FORMAT_DOUBLE, &time)
            let title = getString(mpv, "chapter-list/\(i)/title") ?? "Chương \(i + 1)"
            list.append(Chapter(id: i, title: title, time: time))
        }
        publish { $0.chapters = list }
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

    /// Refresh rate of the screen showing the video (iPhone and iPad run Metal layers at 60 Hz unless the
    /// app opts into ProMotion). Apple TV switches modes per film, so it is left to mpv there.
    private static func displayRefreshRate(_ view: MPVVideoView) -> Double {
        #if os(macOS)
        return Double((view.window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 0)
        #elseif os(iOS)
        return Double(min(60, UIScreen.main.maximumFramesPerSecond))
        #else
        return 0
        #endif
    }

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
