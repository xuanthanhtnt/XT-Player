import Foundation
import SwiftData

enum AppDatabase {
    static let schema = Schema([MediaEntry.self, MediaServer.self, LibraryFolder.self, LibraryItem.self, LibraryFile.self])

    /// Opens the store; an incompatible store from an older build is replaced instead of crashing at launch.
    static func makeContainer() -> ModelContainer {
        let configuration = storeConfiguration()
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            let path = configuration.url.path
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
            if let fresh = try? ModelContainer(for: schema, configurations: [configuration]) {
                return fresh
            }
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }

    private static func storeConfiguration() -> ModelConfiguration {
        #if os(tvOS)
        // tvOS only allows writing to Caches; the library can be rebuilt by a rescan if it is purged.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ModelConfiguration(schema: schema, url: caches.appendingPathComponent("XTPlayer.store"))
        #else
        return ModelConfiguration(schema: schema)
        #endif
    }
}
