#if !os(tvOS)
import Foundation
import Network

/// Random-access bytes of one media file, read from any thread.
protocol ByteSource: AnyObject {
    var size: Int64 { get }
    func read(at offset: Int64, count: Int) -> Data?
    func close()
}

/// A tiny HTTP/1.1 server (GET / HEAD with byte ranges) on the LAN address, so an Apple TV can pull a file
/// that only this device can read: SMB shares through the xtsmb:// bridge, local files, authenticated WebDAV.
/// Used for AirPlay, where AVPlayer hands the URL to the TV.
final class LocalStreamServer: @unchecked Sendable {
    static let shared = LocalStreamServer()

    private let queue = DispatchQueue(label: "xt.http.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var sources: [String: (source: ByteSource, mime: String)] = [:]

    /// Publishes a playback location and returns the URL the TV should open, nil when it cannot be served
    /// (no LAN address, unreadable file).
    func publish(location: String) -> (url: URL, token: String)? {
        guard let host = Self.lanAddress(), let port = startIfNeeded() else { return nil }
        guard let source = Self.makeSource(location) else { return nil }
        let name = (URL(string: location)?.lastPathComponent ?? (location as NSString).lastPathComponent)
        let ext = (name as NSString).pathExtension.lowercased()
        let token = UUID().uuidString
        lock.lock()
        sources[token] = (source, Self.mimeType(ext))
        lock.unlock()
        guard let url = URL(string: "http://\(host):\(port)/\(token)/media.\(ext.isEmpty ? "mp4" : ext)") else { return nil }
        return (url, token)
    }

    func unpublish(_ token: String) {
        lock.lock()
        let entry = sources.removeValue(forKey: token)
        lock.unlock()
        entry?.source.close()
    }

    private func source(for token: String) -> (source: ByteSource, mime: String)? {
        lock.lock()
        defer { lock.unlock() }
        return sources[token]
    }

    // MARK: Listener

    private func startIfNeeded() -> UInt16? {
        lock.lock()
        if listener != nil, port > 0 {
            defer { lock.unlock() }
            return port
        }
        lock.unlock()
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let port = listener.port?.rawValue, port > 0 else {
            listener.cancel()
            return nil
        }
        lock.lock()
        self.listener = listener
        self.port = port
        lock.unlock()
        return port
    }

    // MARK: Connections

    /// Each connection gets its own queue: reads from the NAS block it, never the listener or other clients.
    private func serve(_ connection: NWConnection) {
        let queue = DispatchQueue(label: "xt.http.connection")
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return finish(connection, status: "405 Method Not Allowed")
        }
        let token = parts[1].split(separator: "/").first.map(String.init) ?? ""
        guard let entry = source(for: token) else { return finish(connection, status: "404 Not Found") }
        let source = entry.source
        let size = source.size
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }

        var start: Int64 = 0
        var end = size - 1
        var partial = false
        if let rangeHeader, let spec = rangeHeader.split(separator: "=", maxSplits: 1).last {
            let bounds = spec.split(separator: ",").first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
            if bounds.count == 2 {
                let first = bounds[0].trimmingCharacters(in: .whitespaces)
                let last = bounds[1].trimmingCharacters(in: .whitespaces)
                if first.isEmpty, let suffix = Int64(last) {
                    start = max(0, size - suffix)
                } else if let from = Int64(first) {
                    start = from
                    if let to = Int64(last) { end = min(to, size - 1) }
                }
                partial = true
            }
        }
        guard size > 0, start <= end, start < size else {
            return finish(connection, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n")
        }

        let length = end - start + 1
        var header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        header += "Content-Type: \(entry.mime)\r\nAccept-Ranges: bytes\r\nContent-Length: \(length)\r\n"
        if partial { header += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        header += "Connection: keep-alive\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return connection.cancel() }
            if parts[0] == "HEAD" {
                self.receiveRequest(connection, buffer: Data())
            } else {
                self.sendBody(connection, source: source, from: start, through: end)
            }
        })
    }

    /// Streams the range in 1 MiB pieces, each sent only after the previous one left (back-pressure).
    private func sendBody(_ connection: NWConnection, source: ByteSource, from offset: Int64, through end: Int64) {
        guard offset <= end else { return receiveRequest(connection, buffer: Data()) }
        let count = Int(min(Int64(1 << 20), end - offset + 1))
        guard let data = source.read(at: offset, count: count), !data.isEmpty else { return connection.cancel() }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return connection.cancel() }
            self.sendBody(connection, source: source, from: offset + Int64(data.count), through: end)
        })
    }

    private func finish(_ connection: NWConnection, status: String, extra: String = "") {
        let response = "HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Helpers

    private static func makeSource(_ location: String) -> ByteSource? {
        if location.hasPrefix("xtsmb:") { return SMBByteSource(uri: location) }
        if location.hasPrefix("http:") || location.hasPrefix("https:") { return HTTPByteSource(location) }
        return FileByteSource(path: location)
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "avi": return "video/x-msvideo"
        default: return "application/octet-stream"
        }
    }

    /// IPv4 address of the Wi-Fi / Ethernet interface (the network an Apple TV can reach); VPN tunnels are skipped.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((String(cString: entry.ifa_name), String(cString: host)))
        }
        return candidates.first { $0.name.hasPrefix("en") }?.address
            ?? candidates.first { !$0.name.hasPrefix("utun") && !$0.name.hasPrefix("ipsec") && !$0.name.hasPrefix("ppp") }?.address
    }
}

// MARK: - Sources

/// SMB file through the same multi-connection stream mpv uses; requests are served one at a time.
private final class SMBByteSource: ByteSource, @unchecked Sendable {
    private let stream: SMBReadStream
    private let lock = NSLock()
    var size: Int64 { stream.size }

    init?(uri: String) {
        guard let stream = SMBReadStream.open(uri: uri) else { return nil }
        self.stream = stream
    }

    func read(at offset: Int64, count: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard stream.seek(to: offset) == offset else { return nil }
        var data = Data(count: count)
        var filled = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return false }
            while filled < count {
                let n = stream.read(into: base.advanced(by: filled), count: count - filled)
                if n < 0 { return false }
                if n == 0 { break }
                filled += Int(n)
            }
            return true
        }
        guard ok else { return nil }
        return data.prefix(filled)
    }

    func close() {
        stream.cancel()
        stream.close()
    }
}

private final class FileByteSource: ByteSource, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    let size: Int64

    init?(path: String) {
        guard let handle = FileHandle(forReadingAtPath: path),
              let size = try? handle.seekToEnd() else { return nil }
        self.handle = handle
        self.size = Int64(size)
    }

    func read(at offset: Int64, count: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.read(upToCount: count)
    }

    func close() {
        try? handle.close()
    }
}

/// WebDAV / HTTP file: each piece is a ranged GET (credentials from the URL become a Basic header).
private final class HTTPByteSource: ByteSource, @unchecked Sendable {
    private let url: URL
    private let authorization: String?
    private let session = URLSession(configuration: .ephemeral)
    private(set) var size: Int64 = 0

    init?(_ location: String) {
        guard var parts = URLComponents(string: location) else { return nil }
        if let user = parts.user {
            let credentials = "\(user.removingPercentEncoding ?? user):\((parts.password ?? "").removingPercentEncoding ?? "")"
            authorization = "Basic " + Data(credentials.utf8).base64EncodedString()
        } else {
            authorization = nil
        }
        parts.user = nil
        parts.password = nil
        guard let url = parts.url else { return nil }
        self.url = url
        guard let probe = fetch(range: "bytes=0-0"), let total = Self.totalSize(probe.response) else { return nil }
        size = total
    }

    func read(at offset: Int64, count: Int) -> Data? {
        fetch(range: "bytes=\(offset)-\(offset + Int64(count) - 1)")?.data
    }

    func close() {
        session.invalidateAndCancel()
    }

    private func fetch(range: String) -> (data: Data, response: HTTPURLResponse)? {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let semaphore = DispatchSemaphore(value: 0)
        let box = FetchBox()
        session.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) { box.result = (data, http) }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 30) == .success, let result = box.result else { return nil }
        return (data: result.0, response: result.1)
    }

    private final class FetchBox: @unchecked Sendable {
        var result: (Data, HTTPURLResponse)?
    }

    private static func totalSize(_ response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last {
            return Int64(total)
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }
}
#endif
