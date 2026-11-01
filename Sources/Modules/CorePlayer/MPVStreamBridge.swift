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
///
/// SMBClient keeps one request in flight per connection, so a single connection tops out at
/// chunk / (round trip + NAS disk latency) — below a 4K remux's bitrate over Wi-Fi, which made mpv stop
/// for cache every few seconds. The file is therefore read in 1 MiB chunks by several worker threads,
/// each with its own SMB connection, up to `maxReadAhead` chunks ahead of mpv's read position.
/// A worker whose connection fails (the NAS drops idle sessions during a long pause) reconnects.
final class SMBReadStream: @unchecked Sendable {
    let size: Int64

    private static let chunkSize = 1 << 20
    private static let maxWorkers = 4
    /// The read-ahead window doubles while mpv reads sequentially and shrinks back after a jump, so
    /// probing reads (MKV cues at the end of the file) do not start a burst of useless prefetches.
    private static let minReadAhead = 4
    private static let maxReadAhead = 16
    private static let maxCachedChunks = 40
    private static let maxAttempts = 3

    private let server: ServerCredentials
    private let share: String
    private let path: String
    private let chunkCount: Int

    private var position: Int64 = 0             // mpv's demuxer thread only

    private let condition = NSCondition()        // guards everything below
    private var chunks: [Int: Data] = [:]
    private var lastUse: [Int: UInt64] = [:]
    private var useClock: UInt64 = 0
    private var inFlight: Set<Int> = []
    private var failures: [Int: Int] = [:]
    private var current = 0                      // chunk under mpv's read position
    private var readAhead = minReadAhead
    private var liveWorkers = 0
    private var cancelled = false
    private var closed = false

    private init(server: ServerCredentials, share: String, path: String, size: Int64) {
        self.server = server
        self.share = share
        self.path = path
        self.size = size
        chunkCount = Int((size + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize))
    }

    /// `xtsmb://<server-id>/<share>/<path/to/file>`
    static func open(uri: String) -> SMBReadStream? {
        guard let parts = URLComponents(string: uri), let id = parts.host,
              let server = RemoteCredentialStore.shared.credentials(for: id) else { return nil }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2 else { return nil }
        let share = segments[0]
        let path = segments.dropFirst().joined(separator: "/")
        let opened = blocking(timeout: 30) { () -> (SMBLink, UInt64) in
            let link = try await SMBLink.connect(server, share: share, path: path)
            do {
                return (link, try await link.reader.fileSize)
            } catch {
                link.abort()
                throw error
            }
        }
        guard case let .success((link, size)) = opened else {
            if case let .failure(error) = opened { MPVLogBuffer.shared.append("[xt] smb open \(share)/\(path): \(error)") }
            return nil
        }
        let stream = SMBReadStream(server: server, share: share, path: path, size: Int64(size))
        stream.startWorkers(first: link)
        return stream
    }

    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> Int64 {
        guard count > 0 else { return 0 }
        if position >= size { return 0 }
        let index = Int(position / Int64(Self.chunkSize))

        condition.lock()
        moveReader(to: index)
        let deadline = Date().addingTimeInterval(60)
        var chunk = chunks[index]
        while chunk == nil {
            if cancelled || closed || liveWorkers == 0 || failures[index, default: 0] >= Self.maxAttempts
                || !condition.wait(until: deadline) {
                condition.unlock()
                return -1
            }
            chunk = chunks[index]
        }
        useClock += 1
        lastUse[index] = useClock
        condition.unlock()

        guard let chunk else { return -1 }
        let start = Int(position - Int64(index) * Int64(Self.chunkSize))
        guard start < chunk.count else { return 0 }  // the file shrank since it was opened
        let n = min(count, chunk.count - start)
        chunk.withUnsafeBytes { raw in
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
        if offset < size {
            // Start fetching the new position while mpv is still busy with the seek.
            condition.lock()
            moveReader(to: Int(offset / Int64(Self.chunkSize)))
            condition.unlock()
        }
        return offset
    }

    /// Called by mpv from another thread to interrupt a blocked read (stop / next file).
    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    /// Workers finish their current request, then close their connections.
    func close() {
        condition.lock()
        closed = true
        chunks.removeAll()
        lastUse.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Workers

    private func startWorkers(first: SMBLink) {
        let count = min(Self.maxWorkers, max(1, chunkCount))
        condition.lock()
        liveWorkers = count
        condition.unlock()
        for number in 0..<count {
            let thread = Thread { [self] in work(number: number, link: number == 0 ? first : nil) }
            thread.name = "xt.smb.read.\(number)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// One worker: takes the chunk nearest the reader, fetches it on its own connection, repeats.
    /// Extra connections the NAS refuses are given up; the last worker keeps retrying.
    private func work(number: Int, link initial: SMBLink?) {
        var link = initial
        var retired = false
        defer {
            link?.close()
            if !retired {
                condition.lock()
                liveWorkers -= 1
                condition.broadcast()
                condition.unlock()
            }
        }
        while let index = nextJob() {
            if link == nil {
                switch Self.blocking(timeout: 20, { try await SMBLink.connect(self.server, share: self.share, path: self.path) }) {
                case let .success(newLink):
                    link = newLink
                case let .failure(error):
                    condition.lock()
                    inFlight.remove(index)
                    if liveWorkers > 1 {
                        liveWorkers -= 1
                        retired = true
                    } else {
                        failures[index, default: 0] += 1
                    }
                    condition.broadcast()
                    condition.unlock()
                    MPVLogBuffer.shared.append("[xt] smb connection \(number): \(error)\(retired ? " — continuing with fewer connections" : "")")
                    if retired { return }
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
            }
            guard let active = link else { continue }
            let offset = UInt64(index) * UInt64(Self.chunkSize)
            let length = UInt32(min(Int64(Self.chunkSize), size - Int64(offset)))
            switch Self.blocking(timeout: 30, { try await active.reader.read(offset: offset, length: length) }) {
            case let .success(data):
                StreamTrafficMeter.shared.add(data.count)
                finish(index, data: data)
            case let .failure(error):
                // The connection state is unknown after an error or timeout: drop it and reconnect.
                active.abort()
                link = nil
                finish(index, data: nil)
                MPVLogBuffer.shared.append("[xt] smb read @\(offset) on connection \(number): \(error) — reconnecting")
            }
        }
    }

    /// The missing chunk nearest the reader inside the read-ahead window; blocks while there is none.
    /// nil once the stream is cancelled or closed.
    private func nextJob() -> Int? {
        condition.lock()
        defer { condition.unlock() }
        while !cancelled && !closed {
            let end = min(chunkCount, current + readAhead)
            if current < end {
                for index in current..<end
                where chunks[index] == nil && !inFlight.contains(index) && failures[index, default: 0] < Self.maxAttempts {
                    inFlight.insert(index)
                    return index
                }
            }
            condition.wait()
        }
        return nil
    }

    private func finish(_ index: Int, data: Data?) {
        condition.lock()
        inFlight.remove(index)
        if let data, !closed {
            chunks[index] = data
            useClock += 1
            lastUse[index] = useClock
            failures[index] = nil
            evictIfNeeded()
        } else if data == nil {
            failures[index, default: 0] += 1
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Caller holds `condition`.
    private func moveReader(to index: Int) {
        guard index != current else { return }
        if index > current && index - current <= 2 {
            readAhead = min(Self.maxReadAhead, readAhead * 2)
        } else if abs(index - current) > 2 && chunks[index] == nil && !inFlight.contains(index) {
            // A jump into unread territory. Jumps between regions already being read are normal for
            // MP4s whose audio and video lie far apart in the file, and keep the window as it is.
            readAhead = Self.minReadAhead
        }
        current = index
        condition.broadcast()
    }

    /// Drops the least recently used chunks outside the read-ahead window. Caller holds `condition`.
    private func evictIfNeeded() {
        let excess = chunks.count - Self.maxCachedChunks
        guard excess > 0 else { return }
        let window = (current - 1)..<(current + readAhead)
        let victims = chunks.keys
            .filter { !window.contains($0) }
            .sorted { lastUse[$0, default: 0] < lastUse[$1, default: 0] }
            .prefix(excess)
        for index in victims {
            chunks[index] = nil
            lastUse[index] = nil
        }
    }

    private static func blocking<T>(timeout: TimeInterval, _ operation: @escaping () async throws -> T) -> Result<T, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            do {
                box.set(.success(try await operation()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success, let result = box.get() else {
            return .failure(RemoteError.message("SMB: hết thời gian chờ \(Int(timeout)) s"))
        }
        return result
    }
}

/// Bytes fetched from NAS shares by the stream bridge. mpv's `cache-speed` cannot be used for xtsmb://
/// because it also counts re-reads served from the chunk cache.
final class StreamTrafficMeter: @unchecked Sendable {
    static let shared = StreamTrafficMeter()
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ bytes: Int) {
        lock.lock()
        total += Int64(bytes)
        lock.unlock()
    }

    var totalBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

/// One authenticated SMB connection with the file open for reading; used by one thread at a time.
private final class SMBLink: @unchecked Sendable {
    let client: SMBClient
    let reader: FileReader

    private init(client: SMBClient, reader: FileReader) {
        self.client = client
        self.reader = reader
    }

    static func connect(_ server: ServerCredentials, share: String, path: String) async throws -> SMBLink {
        let client = try await SMBLogin.connect(server)
        do {
            _ = try await client.connectShare(share)
            return SMBLink(client: client, reader: client.fileReader(path: path))
        } catch {
            client.session.disconnect()
            throw error
        }
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

    /// Drops the connection without the polite close/logoff (its state is unknown after an error).
    func abort() {
        client.session.disconnect()
    }
}

/// Hands a result from a detached task back to the blocked thread.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ newValue: Result<T, Error>) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
