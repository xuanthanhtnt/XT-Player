import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Libmpv

/// Grabs one frame of a video as a JPEG with a headless libmpv core, for library items TMDb has no artwork
/// for — the way Infuse shows a still from the video. xtsmb:// goes through the stream bridge.
/// MPVKit's FFmpeg has no image encoders (vo=image cannot save), so the frame is taken with
/// `screenshot-raw` and encoded with ImageIO.
enum FrameGrabber {
    /// What the file turned out to be (Infuse shows it for files TMDb does not know).
    struct Probe {
        let duration: Double
        let width: Int
        let height: Int

        var resolutionLabel: String { VideoSignal(width: width, height: height).resolutionLabel }
    }

    /// Blocking; call off the main thread. The frame is taken at `fraction` of the duration; nil = no frame.
    static func grab(_ location: String, to output: URL, at fraction: Double = 0.2, timeout: TimeInterval = 45) -> Probe? {
        guard let mpv = mpv_create() else { return nil }
        defer { mpv_terminate_destroy(mpv) }

        let settings: [(String, String)] = [
            ("config", "no"),
            ("vo", "null"),
            ("pause", "yes"),
            ("start", "\(Int(fraction * 100))%"),
            ("hr-seek", "no"),
            ("aid", "no"),
            ("sid", "no"),
            ("sub-auto", "no"),
            ("hwdec", "auto-copy"),
            ("vf", "scale=w=1280:h=-2"),
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
            mpv_set_option_string(mpv, name, value)
        }
        guard mpv_initialize(mpv) >= 0 else { return nil }
        MPVStreamProtocols.register(on: mpv)
        guard command(mpv, ["loadfile", location]) else { return nil }

        // Paused from the start, mpv stops on the first frame after the initial seek.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let event = mpv_wait_event(mpv, 0.5) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_PLAYBACK_RESTART:
                for _ in 0..<10 {
                    if let image = rawFrame(mpv) {
                        guard writeJPEG(image, to: output) else { return nil }
                        var duration = 0.0
                        mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration)
                        var width: Int64 = 0, height: Int64 = 0
                        mpv_get_property(mpv, "video-dec-params/w", MPV_FORMAT_INT64, &width)
                        mpv_get_property(mpv, "video-dec-params/h", MPV_FORMAT_INT64, &height)
                        return Probe(duration: duration, width: Int(width), height: Int(height))
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                return nil
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// The displayed frame as a CGImage (`screenshot-raw` returns bgr0 pixels). Also used by `ScrubThumbnailer`.
    static func rawFrame(_ mpv: OpaquePointer) -> CGImage? {
        let words: [String] = ["screenshot-raw", "video"]
        var args: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) }
        args.append(nil)
        defer { args.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var result = mpv_node()
        guard mpv_command_ret(mpv, &args, &result) >= 0 else { return nil }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list?.pointee,
              let keys = list.keys, let values = list.values else { return nil }

        var width = 0, height = 0, stride = 0
        var pixels: Data?
        for i in 0..<Int(list.num) {
            guard let key = keys[i] else { continue }
            let value = values[i]
            switch String(cString: key) {
            case "w": width = Int(value.u.int64)
            case "h": height = Int(value.u.int64)
            case "stride": stride = Int(value.u.int64)
            case "data":
                if value.format == MPV_FORMAT_BYTE_ARRAY, let array = value.u.ba?.pointee, let bytes = array.data {
                    pixels = Data(bytes: bytes, count: array.size)
                }
            default: break
            }
        }
        guard width > 0, height > 0, stride >= width * 4, let pixels, pixels.count >= stride * height,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func writeJPEG(_ image: CGImage, to output: URL) -> Bool {
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    static func command(_ mpv: OpaquePointer, _ words: [String]) -> Bool {
        var args: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) }
        args.append(nil)
        defer { args.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        return mpv_command(mpv, &args) >= 0
    }
}

/// Artwork generated on the device, referenced from the TMDb image fields as "local:<file name>"
/// (`TMDbClient.imageURL` resolves it). Kept in Caches: if the system purges it, it is generated again.
enum ThumbnailStore {
    static let prefix = "local:"

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// Stable reference for the library file `key`.
    static func reference(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return prefix + digest.prefix(24) + ".jpg"
    }

    static func url(for path: String) -> URL? {
        guard path.hasPrefix(prefix) else { return nil }
        return directory.appendingPathComponent(String(path.dropFirst(prefix.count)))
    }

    private static let failedKey = "artwork.failed"

    /// A frame could not be taken from this file in the last week (no video, no embedded cover, unreadable).
    static func recentlyFailed(_ key: String) -> Bool {
        let failed = UserDefaults.standard.dictionary(forKey: failedKey) as? [String: Date] ?? [:]
        guard let date = failed[key] else { return false }
        return Date().timeIntervalSince(date) < 7 * 24 * 3600
    }

    static func markFailed(_ key: String) {
        var failed = UserDefaults.standard.dictionary(forKey: failedKey) as? [String: Date] ?? [:]
        failed[key] = .now
        UserDefaults.standard.set(failed, forKey: failedKey)
    }

    /// TMDb paths count as artwork; local ones only while their file exists.
    static func isUsable(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        guard let url = url(for: path) else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
