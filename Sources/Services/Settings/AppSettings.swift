import Foundation
import Security

/// UserDefaults keys + defaults. Views bind with @AppStorage(AppSettings.x).
enum AppSettings {
    static let hdrPassthrough = "player.hdrPassthrough"
    static let audioPassthrough = "player.audioPassthrough"
    static let deinterlace = "player.deinterlace"
    static let cacheMegabytes = "player.cacheMegabytes"
    static let autoplayNext = "player.autoplayNext"
    static let skipBackSeconds = "player.skipBack"
    static let skipForwardSeconds = "player.skipForward"
    static let subtitleLanguages = "subtitles.languages"
    static let audioLanguages = "audio.languages"
    static let subtitleScale = "subtitles.scale"
    static let subtitlePosition = "subtitles.position"
    static let subtitleBackground = "subtitles.background"
    static let metadataLanguage = "library.language"
    static let openSubtitlesUser = "opensubtitles.username"
    static let hardwareDecoding = "player.hardwareDecoding"
    static let pictureQuality = "player.pictureQuality"
    static let motionSmoothing = "player.motionSmoothing"
    static let matchSampleRate = "audio.matchSampleRate"
    static let nightMode = "audio.nightMode"
    static let dialogBoost = "audio.dialogBoost"

    static func registerDefaults() {
        #if os(macOS)
        let cache = 1024
        #else
        let cache = 400
        #endif
        UserDefaults.standard.register(defaults: [
            hdrPassthrough: true,
            audioPassthrough: false,
            deinterlace: "auto",
            cacheMegabytes: cache,
            autoplayNext: true,
            skipBackSeconds: 10,
            skipForwardSeconds: 30,
            subtitleLanguages: "vi,vie,en,eng",
            audioLanguages: "",
            subtitleScale: 1.0,
            subtitlePosition: 100,
            subtitleBackground: false,
            metadataLanguage: "vi-VN",
            hardwareDecoding: true,
            pictureQuality: PictureQuality.platformDefault.rawValue,
            motionSmoothing: false,
            matchSampleRate: false,
            nightMode: false,
            dialogBoost: false,
        ])
    }

    static var defaults: UserDefaults { .standard }

    /// The Trakt API application: user setting first, then the build-time one (CI secrets TRAKT_CLIENT_ID /
    /// TRAKT_CLIENT_SECRET). Apps created since October 2026 sign in with PKCE and have no secret (nil).
    static var traktClient: (id: String, secret: String?)? {
        if let id = Keychain.get(account: "trakt.clientID"), !id.isEmpty {
            let secret = Keychain.get(account: "trakt.clientSecret")
            return (id, secret?.isEmpty == false ? secret : nil)
        }
        if let id = Bundle.main.object(forInfoDictionaryKey: "XTTraktClientID") as? String, !id.isEmpty, !id.hasPrefix("$(") {
            let secret = Bundle.main.object(forInfoDictionaryKey: "XTTraktClientSecret") as? String
            return (id, secret.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 })
        }
        return nil
    }

    /// OpenSubtitles.com API key: user setting first, then the build-time key (CI secret OPENSUBTITLES_API_KEY).
    static var openSubtitlesKey: String? {
        if let user = Keychain.get(account: "opensubtitles"), !user.isEmpty { return user }
        if let built = Bundle.main.object(forInfoDictionaryKey: "XTOpenSubtitlesAPIKey") as? String,
           !built.isEmpty, !built.hasPrefix("$(") {
            return built
        }
        return nil
    }

    /// TMDb v3 API key or v4 read-access token: user setting first, then the build-time key (CI secret).
    static var tmdbCredential: String? {
        if let user = Keychain.get(account: "tmdb"), !user.isEmpty { return user }
        if let built = Bundle.main.object(forInfoDictionaryKey: "XTTMDbAPIKey") as? String,
           !built.isEmpty, !built.hasPrefix("$(") {
            return built
        }
        return nil
    }
}

/// Minimal generic-password Keychain wrapper. Falls back to UserDefaults when the Keychain is not
/// usable (e.g. an ad-hoc signed macOS build), so credentials still work there.
enum Keychain {
    /// The app's own bundle id, so a side-by-side test copy never reads (or prompts for) the real app's items.
    private static let service = Bundle.main.bundleIdentifier ?? "com.xuanthanhtnt.xtplayer"

    static func set(_ value: String?, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(account))
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: fallbackKey(account))
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return UserDefaults.standard.string(forKey: fallbackKey(account))
    }

    private static func fallbackKey(_ account: String) -> String { "kc.fallback.\(account)" }
}
