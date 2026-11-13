import CoreGraphics
import Foundation
import Libmpv
import SwiftUI

/// Preview frames above the scrubber, like Infuse. A second, headless libmpv core opens the same file the first
/// time the user scrubs and keyframe-seeks to the time under the pointer. Only the newest request is worked on
/// (the pointer moves faster than frames decode) and frames are cached per `bucketSeconds`.
@MainActor
final class ScrubThumbnailer: ObservableObject {
    @Published private(set) var images: [Int: CGImage] = [:]

    private static let bucketSeconds = 10.0
    private static let maxImages = 360
    private var location: String?
    private let worker = ThumbnailWorker()

    /// A new file is playing (nil = the player closed).
    func reset(location: String?) {
        self.location = location
        images = [:]
        worker.close()
    }

    /// The frame for `seconds`, else the nearest one already decoded close by.
    func image(at seconds: Double) -> CGImage? {
        guard seconds.isFinite else { return nil }
        let bucket = Self.bucket(seconds)
        if let exact = images[bucket] { return exact }
        for distance in 1...3 {
            if let near = images[bucket - distance] ?? images[bucket + distance] { return near }
        }
        return nil
    }

    func request(_ seconds: Double) {
        guard let location, seconds.isFinite, seconds >= 0 else { return }
        let bucket = Self.bucket(seconds)
        guard images[bucket] == nil else { return }
        worker.request(location: location, bucket: bucket, time: Double(bucket) * Self.bucketSeconds) { [weak self] bucket, image in
            Task { @MainActor in
                guard let self, self.location == location else { return }
                if self.images.count >= Self.maxImages, let far = self.images.keys.max(by: { abs($0 - bucket) < abs($1 - bucket) }) {
                    self.images[far] = nil
                }
                self.images[bucket] = image
            }
        }
    }

    private static func bucket(_ seconds: Double) -> Int {
        Int(max(0, seconds) / bucketSeconds)
    }
}

/// Owns the headless core; every libmpv call happens on `queue`.
private final class ThumbnailWorker: @unchecked Sendable {
    private struct Job {
        let location: String
        let bucket: Int
        let time: Double
        let completion: (Int, CGImage) -> Void
    }

    private let queue = DispatchQueue(label: "xt.scrub.thumbnails", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Job?
    private var draining = false

    private var mpv: OpaquePointer?      // queue only
    private var openLocation: String?    // queue only

    func request(location: String, bucket: Int, time: Double, completion: @escaping (Int, CGImage) -> Void) {
        lock.lock()
        pending = Job(location: location, bucket: bucket, time: time, completion: completion)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func close() {
        lock.lock()
        pending = nil
        lock.unlock()
        queue.async { self.destroy() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            if let image = render(job) { job.completion(job.bucket, image) }
        }
    }

    private func render(_ job: Job) -> CGImage? {
        if openLocation != job.location {
            destroy()
            guard open(job.location) else { return nil }
        }
        guard let mpv, FrameGrabber.command(mpv, ["seek", String(format: "%.3f", job.time), "absolute+keyframes"]),
              wait(for: MPV_EVENT_PLAYBACK_RESTART, timeout: 6) else { return nil }
        return FrameGrabber.rawFrame(mpv)
    }

    private func open(_ location: String) -> Bool {
        guard let core = mpv_create() else { return false }
        let settings: [(String, String)] = [
            ("config", "no"),
            ("vo", "null"),
            ("pause", "yes"),
            ("keep-open", "yes"),
            ("hr-seek", "no"),
            ("aid", "no"),
            ("sid", "no"),
            ("sub-auto", "no"),
            ("hwdec", "auto-copy"),
            ("vf", "scale=w=320:h=-2"),
            ("demuxer-max-bytes", "24MiB"),
            ("demuxer-readahead-secs", "1"),
            ("load-scripts", "no"),
            ("osc", "no"),
            ("ytdl", "no"),
            ("input-default-bindings", "no"),
            ("load-stats-overlay", "no"),
            ("load-console", "no"),
            ("load-select", "no"),
            ("load-auto-profiles", "no"),
            ("load-positioning", "no"),
            ("load-commands", "no"),
        ]
        for (name, value) in settings {
            mpv_set_option_string(core, name, value)
        }
        guard mpv_initialize(core) >= 0 else {
            mpv_terminate_destroy(core)
            return false
        }
        MPVStreamProtocols.register(on: core)
        mpv = core
        // The first frame after loading also ends in a playback restart.
        guard FrameGrabber.command(core, ["loadfile", location]), wait(for: MPV_EVENT_PLAYBACK_RESTART, timeout: 20) else {
            destroy()
            return false
        }
        openLocation = location
        return true
    }

    private func destroy() {
        if let mpv { mpv_terminate_destroy(mpv) }
        mpv = nil
        openLocation = nil
    }

    /// Waits for `target`; false on timeout or end of file.
    private func wait(for target: mpv_event_id, timeout: TimeInterval) -> Bool {
        guard let mpv else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let event = mpv_wait_event(mpv, 0.25) else { continue }
            switch event.pointee.event_id {
            case target: return true
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN: return false
            default: continue
            }
        }
        return false
    }
}

/// A decoded preview frame (scrub thumbnails).
struct ScrubPreviewImage: View {
    let image: CGImage
    let width: CGFloat

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
