import Foundation
import Network

/// A file server announced on the local network over Bonjour.
struct DiscoveredServer: Identifiable, Hashable {
    var id: String { name + kind.rawValue }
    let name: String
    let kind: ServerKind
    let endpoint: NWEndpoint
}

/// Finds SMB (and WebDAV) servers on the LAN, like Infuse's "nearby shares".
@MainActor
final class ServerDiscovery: ObservableObject {
    @Published private(set) var servers: [DiscoveredServer] = []
    private var browsers: [NWBrowser] = []

    func start() {
        guard browsers.isEmpty else { return }
        for (type, kind) in [("_smb._tcp", ServerKind.smb), ("_webdav._tcp", ServerKind.webdav), ("_webdavs._tcp", ServerKind.webdav)] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let list: [DiscoveredServer] = results.compactMap { result in
                    if case let .service(name, _, _, _) = result.endpoint {
                        return DiscoveredServer(name: name, kind: kind, endpoint: result.endpoint)
                    }
                    return nil
                }
                Task { @MainActor [weak self] in self?.update(type: type, kind: kind, list: list) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
    }

    private var byType: [String: [DiscoveredServer]] = [:]

    private func update(type: String, kind: ServerKind, list: [DiscoveredServer]) {
        byType[type] = list
        var seen = Set<String>()
        servers = byType.values.flatMap { $0 }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Resolves a Bonjour service to an IPv4 address (falls back to "<name>.local").
    nonisolated static func resolveHost(_ server: DiscoveredServer) async -> String {
        let resolved: String? = await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "xt.discovery.resolve")
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: server.endpoint, using: parameters)
            let once = ResolveOnce()
            // Every callback below runs on `queue`, so `once` needs no lock.
            let finish: (String?) -> Void = { value in
                guard !once.done else { return }
                once.done = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint {
                        switch host {
                        case let .ipv4(address): finish("\(address)")
                        case let .ipv6(address): finish("\(address)")
                        case let .name(name, _): finish(name)
                        @unknown default: finish(nil)
                        }
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
        if let resolved, !resolved.isEmpty {
            return resolved.components(separatedBy: "%").first ?? resolved
        }
        let safe = server.name.replacingOccurrences(of: " ", with: "-")
        return "\(safe).local"
    }
}

private final class ResolveOnce: @unchecked Sendable {
    var done = false
}
