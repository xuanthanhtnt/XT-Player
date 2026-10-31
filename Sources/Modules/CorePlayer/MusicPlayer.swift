import Combine
import Foundation
import SwiftData

/// The app's music player, in the manner of Roon: one queue for the whole app that keeps playing while the library
/// is browsed (a bar at the bottom of the window, a full Now Playing view on demand), gapless between tracks, with
/// play-next / add-to-queue, shuffle and repeat. Videos keep their own full-screen player and pause the music.
@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    enum RepeatMode: CaseIterable {
        case off, all, one
    }

    @Published private(set) var queue: [PlaybackItem] = []
    @Published private(set) var index = 0
    @Published private(set) var isShuffled = false
    @Published private(set) var repeatMode = RepeatMode.off
    @Published var showsNowPlaying = false
    @Published private(set) var engine: MPVPlayerEngine?

    private let nowPlaying = NowPlayingController()
    private var nowPlayingAttached = false
    private var context: ModelContext?
    private var entry: MediaEntry?
    /// Queue order before shuffling, to restore it.
    private var unshuffled: [PlaybackItem] = []
    private var cancellables: Set<AnyCancellable> = []

    var current: PlaybackItem? { queue.indices.contains(index) ? queue[index] : nil }
    var isActive: Bool { !queue.isEmpty }
    var upcoming: ArraySlice<PlaybackItem> { queue.indices.contains(index) ? queue[(index + 1)...] : [] }

    // MARK: Queue

    /// Replaces the queue and starts playing.
    func play(_ items: [PlaybackItem], startAt start: Int = 0, shuffle: Bool = false, context: ModelContext) {
        guard !items.isEmpty else { return }
        self.context = context
        saveProgress()
        var list = items
        var first = max(0, min(start, items.count - 1))
        unshuffled = items
        if shuffle {
            list.shuffle()
            first = 0
        }
        isShuffled = shuffle
        queue = list
        index = first
        list.forEach(register)
        let engine = makeEngine()
        engine.loadPlaylist(list.map(\.source.playbackLocation), start: first)
        trackChanged()
        #if os(tvOS)
        showsNowPlaying = true
        #endif
    }

    /// Plays these right after the current track (Roon's "Play next").
    func playNext(_ items: [PlaybackItem], context: ModelContext) {
        guard isActive, let engine else { return play(items, context: context) }
        items.forEach(register)
        queue.insert(contentsOf: items, at: index + 1)
        unshuffled.append(contentsOf: items)
        // insert-next always goes right after the current entry: insert the last one first.
        for item in items.reversed() { engine.playlistInsertNext(item.source.playbackLocation) }
    }

    /// Adds these at the end of the queue.
    func addToQueue(_ items: [PlaybackItem], context: ModelContext) {
        guard isActive, let engine else { return play(items, context: context) }
        items.forEach(register)
        queue.append(contentsOf: items)
        unshuffled.append(contentsOf: items)
        for item in items { engine.playlistAppend(item.source.playbackLocation) }
    }

    func jump(to position: Int) {
        guard queue.indices.contains(position) else { return }
        saveProgress()
        resumeNowPlaying()
        engine?.playlistPlay(position)
    }

    func remove(at position: Int) {
        guard queue.indices.contains(position), position != index else { return }
        let removed = queue.remove(at: position)
        unshuffled.removeAll { $0.id == removed.id }
        engine?.playlistRemove(position)
        if position < index { index -= 1 }
    }

    /// Drag to reorder (SwiftUI's onMove). mpv's playlist-move has the same meaning as `destination`: the entry
    /// goes before the one that was at that index.
    func move(from source: IndexSet, to destination: Int) {
        guard source.count == 1, let from = source.first, queue.indices.contains(from) else { return }
        let to = from < destination ? destination - 1 : destination
        guard from != to else { return }
        let playing = current?.id
        let item = queue.remove(at: from)
        queue.insert(item, at: to)
        engine?.playlistMove(from, to: destination)
        if let playing, let position = queue.firstIndex(where: { $0.id == playing }) { index = position }
    }

    /// Clears what is left after the current track.
    func clearUpcoming() {
        guard isActive else { return }
        for position in stride(from: queue.count - 1, to: index, by: -1) { engine?.playlistRemove(position) }
        queue.removeSubrange((index + 1)...)
        unshuffled = queue
    }

    func toggleShuffle() {
        guard isActive, let engine, let current else { return }
        isShuffled.toggle()
        // Only what comes after the current track changes order.
        var rest: [PlaybackItem]
        if isShuffled {
            unshuffled = queue
            rest = Array(upcoming).shuffled()
        } else {
            let start = (unshuffled.firstIndex { $0.id == current.id } ?? -1) + 1
            rest = start > 0 ? Array(unshuffled[start...]) : Array(upcoming)
        }
        for position in stride(from: queue.count - 1, to: index, by: -1) { engine.playlistRemove(position) }
        queue = Array(queue[...index]) + rest
        for item in rest { engine.playlistAppend(item.source.playbackLocation) }
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
        engine?.setLoop(playlist: repeatMode == .all, file: repeatMode == .one)
    }

    // MARK: Transport

    func togglePause() {
        guard let engine else { return }
        resumeNowPlaying()
        if engine.state == .ended {
            jump(to: 0)
        } else {
            engine.togglePause()
        }
    }

    func pause() {
        engine?.pause()
        saveProgress()
    }

    /// A video starts: the music pauses and hands the remote / lock-screen controls to the video player.
    func suspendForVideo() {
        guard isActive else { return }
        pause()
        nowPlaying.detach()
        nowPlayingAttached = false
    }

    func next() {
        saveProgress()
        resumeNowPlaying()
        engine?.playlistNext()
    }

    /// Back to the start of the track, or the previous track within the first seconds (like every music player).
    func previous() {
        guard let engine else { return }
        resumeNowPlaying()
        if engine.position > 3 || index == 0 {
            engine.seek(to: 0)
        } else {
            saveProgress()
            engine.playlistPrevious()
        }
    }

    func stop() {
        saveProgress()
        engine?.shutdown()
        engine = nil
        cancellables.removeAll()
        nowPlaying.detach()
        nowPlayingAttached = false
        queue = []
        unshuffled = []
        index = 0
        showsNowPlaying = false
    }

    // MARK: Engine

    private func makeEngine() -> MPVPlayerEngine {
        if let engine { return engine }
        let engine = MPVPlayerEngine(audioOnly: true)
        engine.attachAudioOnly()
        engine.setLoop(playlist: repeatMode == .all, file: repeatMode == .one)
        self.engine = engine
        resumeNowPlaying()
        // A track that ends on its own is saved as listened to when mpv reports the end (below); skips save their
        // position before the command is sent, so here the new track only has to be picked up.
        engine.$playlistPosition
            .removeDuplicates()
            .sink { [weak self] position in
                guard let self, position >= 0, position != self.index, self.queue.indices.contains(position) else { return }
                self.index = position
                self.trackChanged()
            }
            .store(in: &cancellables)
        engine.$state
            .removeDuplicates()
            .sink { [weak self] state in
                switch state {
                case .ended: self?.finishTrack()
                case .paused: self?.saveProgress()
                default: break
                }
            }
            .store(in: &cancellables)
        // What the file really is ("FLAC · 96 kHz · 24-bit"), shown on the album page from then on.
        engine.$audio
            .map { "\($0.sampleRate)|\($0.sampleFormat)" }
            .removeDuplicates()
            .sink { [weak self] _ in self?.learnQuality() }
            .store(in: &cancellables)
        return engine
    }

    /// (Re)claims Control Center / lock screen / media keys, e.g. after a video player had them.
    private func resumeNowPlaying() {
        guard let engine, !nowPlayingAttached else { return }
        nowPlaying.attach(to: engine)
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }
        nowPlayingAttached = true
        if let current {
            nowPlaying.setItem(title: current.title, subtitle: current.subtitle,
                               artworkURL: TMDbClient.imageURL(current.artworkPath, size: "w500"), isMusic: true)
        }
    }

    private func register(_ item: PlaybackItem) {
        if let server = item.server { RemoteCredentialStore.shared.register(server) }
    }

    private func trackChanged() {
        guard let current, let context else { return }
        entry = MediaLibrary.touch(current, in: context)
        try? context.save()
        nowPlaying.setItem(title: current.title, subtitle: current.subtitle,
                           artworkURL: TMDbClient.imageURL(current.artworkPath, size: "w500"), isMusic: true)
    }

    /// The track that just ended counts as listened to (it was played to its end).
    private func finishTrack() {
        guard let entry, let context, let engine, engine.duration > 0 else { return }
        let ended = engine.state == .ended || engine.position >= engine.duration - 2
        MediaLibrary.saveProgress(entry, position: ended ? engine.duration : engine.position, duration: engine.duration, in: context)
    }

    private func saveProgress() {
        guard let entry, let context, let engine, engine.duration > 0 else { return }
        MediaLibrary.saveProgress(entry, position: engine.position, duration: engine.duration, in: context)
    }

    private func learnQuality() {
        guard let engine, let current, let context, engine.audio.sampleRate > 0 else { return }
        let quality = SignalPath.quality(engine.audio)
        guard !quality.isEmpty else { return }
        MediaLibrary.learnTrack(fileKey: current.key, quality: quality, in: context)
    }
}

/// Roon-style signal path: the source, what the app does to it, what the device receives, and an overall grade.
struct SignalPath {
    enum Grade {
        /// Lossless and untouched: the file's own samples at its own rate.
        case bitPerfect
        /// Lossless, but resampled or volume-scaled on the way.
        case highQuality
        /// Deliberate processing (dialogue boost, night mode, levelling).
        case enhanced
        /// The source itself is lossy (MP3, AAC, Opus…).
        case lossy
        /// Between tracks: nothing decoded yet.
        case unknown

        var label: String {
            switch self {
            case .unknown: return "Đang mở…"
            case .bitPerfect: return "Bit-perfect"
            case .highQuality: return "Chất lượng cao"
            case .enhanced: return "Có xử lý"
            case .lossy: return "Nguồn nén (lossy)"
            }
        }
    }

    let source: String
    let processing: [String]
    let output: String
    let grade: Grade

    private static let lossless: Set<String> = [
        "FLAC", "ALAC", "WavPack", "APE", "TTA", "TAK", "PCM", "DSD", "DSD (DST)", "TrueHD", "MLP", "WMALOSSLESS",
    ]

    init(engine: MPVPlayerEngine) {
        let audio = engine.audio
        source = Self.quality(audio)
        var steps: [String] = []
        if audio.outputSampleRate > 0, audio.sampleRate > 0, !audio.isNativeRate {
            let device = audio.deviceSampleRate > 0 ? audio.deviceSampleRate : Double(audio.outputSampleRate)
            steps.append("Lấy mẫu lại \(InfoPanel.kHz(Double(audio.sampleRate))) → \(InfoPanel.kHz(device))")
        }
        if engine.dialogBoost { steps.append("Tăng thoại") }
        if engine.nightMode { steps.append("Chế độ ban đêm") }
        if engine.volumeLeveling { steps.append("Cân bằng âm lượng (ReplayGain)") }
        if engine.isMuted { steps.append("Tắt tiếng") } else if abs(engine.volume - 100) > 0.5 { steps.append("Âm lượng \(Int(engine.volume)) %") }
        processing = steps
        let deviceRate = audio.deviceSampleRate > 0 ? InfoPanel.kHz(audio.deviceSampleRate) : ""
        let device = engine.audioDevices.first { $0.id == engine.audioDevice }?.description
            ?? (engine.audioOutput.isEmpty ? "—" : engine.audioOutput)
        output = [device, deviceRate].filter { !$0.isEmpty }.joined(separator: " · ")
        if audio.codec.isEmpty || audio.sampleRate == 0 {
            grade = .unknown
        } else if !Self.lossless.contains(audio.codec) {
            grade = .lossy
        } else if engine.dialogBoost || engine.nightMode || engine.volumeLeveling {
            grade = .enhanced
        } else if steps.isEmpty {
            grade = .bitPerfect
        } else {
            grade = .highQuality
        }
    }

    /// "FLAC · 96 kHz · 24-bit", "DSD128", "MP3 · 44.1 kHz".
    static func quality(_ audio: AudioSignal) -> String {
        guard audio.sampleRate > 0 else { return audio.codec }
        if audio.codec.hasPrefix("DSD") {
            // FFmpeg turns DSD into PCM at 1/8 of the bit rate: 352.8 kHz = DSD64.
            let multiple = Int((Double(audio.sampleRate) * 8 / 44_100).rounded())
            return "DSD\(multiple)"
        }
        var parts = [audio.codec, InfoPanel.kHz(Double(audio.sampleRate))]
        switch audio.sampleFormat {
        case "s16", "s16p": parts.append("16-bit")
        case "s32", "s32p": parts.append(Self.lossless.contains(audio.codec) && audio.codec != "PCM" ? "24-bit" : "32-bit")
        case "u8", "u8p": parts.append("8-bit")
        default: break
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
