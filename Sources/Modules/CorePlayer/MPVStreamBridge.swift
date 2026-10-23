import Foundation
import Libmpv
import SMBClient

/// Server credentials that mpv's stream callbacks may look up (they run on mpv's demuxer thread and
/// must not touch SwiftData). Registered by the player right before a network file is loaded.
final class RemoteCredentialStore: @unchecked Sendable {
    static let shared = RemoteCredentialStore()
    private let lock = NSLock()
    private var servers: [String: ServerCredentials] = [:]

    func register(_ server: ServerCredentials) {
        lock.lock()
        servers[server.id.lowercased()] = server
        lock.unlock()
    }

    func credentials(for id: String) -> ServerCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return servers[id.lowercased()]
    }
}

/// Registers the app's custom protocols on an mpv core.
enum MPVStreamProtocols {
    static func register(on mpv: OpaquePointer) {
        mpv_stream_cb_add_ro(mpv, "xtsmb", nil) { _, uri, info in
            guard let uri, let info, let stream = SMBReadStream.open(uri: String(cString: uri)) else {
                return MPV_ERROR_LOADING_FAILED.rawValue
            }
            info.pointee.cookie = Unmanaged.passRetained(stream).toOpaque()
            info.pointee.read_fn = { cookie, buffer, count in
                guard let cookie, let buffer else { return -1 }
                let stream = Unmanaged<SMBReadStream>.fromOpaque(cookie).takeUnretainedValue()
                return stream.read(into: buffer, count: Int(min(count, UInt64(Int32.max))))
            }
            info.pointee.seek_fn = { cookie, offset in
                guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
                return Unmanaged<SMBReadStream>.fromOpaque(cookie).takeUnretainedValue().seek(to: offset)
            }
            info.pointee.size_fn = { cookie in
                guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
                return Unmanaged<SMBReadStream>.fromOpaque(cookie).takeUnretainedValue().size
            }
            info.pointee.close_fn = { cookie in
                guard let cookie else { return }
                Unmanaged<SMBReadStream>.fromOpaque(cookie).takeRetainedValue().close()
            }
            info.pointee.cancel_fn = { cookie in
                guard let cookie else { return }
                Unmanaged<SMBReadStream>.fromOpaque(cookie).takeUnretainedValue().cancel()
            }
            return 0
        }
    }
}

/// Random-access SMB file as a blocking byte stream for mpv.
/// Reads are served from a 4 MiB read-ahead window so mpv's small sequential reads become a few large
/// SMB2 READ requests (enough for >100 Mbps remuxes on a LAN).
final class SMBReadStream: @unchecked Sendable {
    let size: Int64

    private let client: SMBClient
    private let reader: FileReader
    private var position: Int64 = 0
    private var window = Data()
    private var windowStart: Int64 = 0
    private let chunkSize: Int64 = 4 << 20

    private let lock = NSLock()
    private var cancelled = false
    private var waiting: DispatchSemaphore?

    private init(client: SMBClient, reader: FileReader, size: Int64) {
        self.client = client
        self.reader = reader
        self.size = size
    }

    /// `xtsmb://<server-id>/<share>/<path/to/file>`
    static func open(uri: String) -> SMBReadStream? {
        guard let parts = URLComponents(string: uri), let id = parts.host,
              let server = RemoteCredentialStore.shared.credentials(for: id) else { return nil }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2 else { return nil }
        let share = segments[0]
        let path = segments.dropFirst().joined(separator: "/")
        return blocking(timeout: 30) {
            let client = try await SMBLogin.connect(server)
            do {
                _ = try await client.connectShare(share)
                let reader = client.fileReader(path: path)
                let size = try await reader.fileSize
                return SMBReadStream(client: client, reader: reader, size: Int64(size))
            } catch {
                client.session.disconnect()
                throw error
            }
        }
    }

    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> Int64 {
        guard count > 0 else { return 0 }
        if isCancelled { return -1 }
        if position >= size { return 0 }

        let inWindow = position >= windowStart && position < windowStart + Int64(window.count)
        if !inWindow {
            let offset = position
            let length = UInt32(min(chunkSize, size - offset))
            let reader = self.reader
            guard let data = blockingCancellable(timeout: 60, { try await reader.read(offset: UInt64(offset), length: length) }) else {
                return -1
            }
            if data.isEmpty { return 0 }
            window = data
            windowStart = offset
        }

        let start = Int(position - windowStart)
        let n = min(count, window.count - start)
        window.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(UnsafeMutableRawPointer(buffer), base.advanced(by: start), n)
            }
        }
        position += Int64(n)
        return Int64(n)
    }

    func seek(to offset: Int64) -> Int64 {
        guard offset >= 0, offset <= size else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        position = offset
        return offset
    }

    /// Called by mpv from another thread to interrupt a blocked read (seek / stop).
    func cancel() {
        lock.lock()
        cancelled = true
        waiting?.signal()
        lock.unlock()
    }

    func close() {
        let reader = self.reader
        let client = self.client
        Task.detached {
            try? await reader.close()
            _ = try? await client.logoff()
            client.session.disconnect()
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func blockingCancellable<T>(timeout: TimeInterval, _ operation: @escaping () async throws -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        lock.lock()
        if cancelled {
            lock.unlock()
            return nil
        }
        waiting = semaphore
        lock.unlock()
        Task.detached {
            box.set(try? await operation())
            semaphore.signal()
        }
        let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
        lock.lock()
        waiting = nil
        let wasCancelled = cancelled
        lock.unlock()
        if timedOut || wasCancelled { return nil }
        return box.get()
    }

    private static func blocking<T>(timeout: TimeInterval, _ operation: @escaping () async throws -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.set(try? await operation())
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.get()
    }
}

/// Hands a value from a detached task back to the blocked mpv thread.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ newValue: T?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
