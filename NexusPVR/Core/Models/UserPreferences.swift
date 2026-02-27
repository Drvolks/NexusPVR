//
//  UserPreferences.swift
//  nextpvr-apple-client
//
//  User preferences and settings - synced via iCloud
//

import Foundation

nonisolated struct PlayerStats: Codable {
    var avgFps: Double = 0
    var avgBitrateKbps: Double = 0
    var totalDroppedFrames: Int64 = 0
    var totalDecoderDroppedFrames: Int64 = 0
    var totalVoDelayedFrames: Int64 = 0
    var maxAvsync: Double = 0

    private static let storageKey = "PlayerStats"

    static func load() -> PlayerStats {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let stats = try? JSONDecoder().decode(PlayerStats.self, from: data) {
            return stats
        }
        return PlayerStats()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

nonisolated struct UserPreferences: Codable {
    var keywords: [String] = []
    var seekBackwardSeconds: Int = 10
    var seekForwardSeconds: Int = 30
    var audioChannels: String = "auto"

    // Migration: keep old property for decoding existing data
    private enum CodingKeys: String, CodingKey {
        case keywords
        case seekBackwardSeconds
        case seekForwardSeconds
        case seekTimeSeconds // legacy
        case audioChannels
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        seekBackwardSeconds = try container.decodeIfPresent(Int.self, forKey: .seekBackwardSeconds) ?? 10
        // Migrate from old seekTimeSeconds if seekForwardSeconds not present
        if let forward = try container.decodeIfPresent(Int.self, forKey: .seekForwardSeconds) {
            seekForwardSeconds = forward
        } else if let legacy = try container.decodeIfPresent(Int.self, forKey: .seekTimeSeconds) {
            seekForwardSeconds = legacy
        } else {
            seekForwardSeconds = 30
        }
        audioChannels = try container.decodeIfPresent(String.self, forKey: .audioChannels) ?? "auto"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keywords, forKey: .keywords)
        try container.encode(seekBackwardSeconds, forKey: .seekBackwardSeconds)
        try container.encode(seekForwardSeconds, forKey: .seekForwardSeconds)
        try container.encode(audioChannels, forKey: .audioChannels)
    }

    private static let storageKey = "UserPreferences"
    private static let ubiquitousStore = NSUbiquitousKeyValueStore.default

    /// In-memory store for demo mode — when set, load/save bypass persistence
    nonisolated(unsafe) static var demoStore: UserPreferences?

    static func load() -> UserPreferences {
        if let demo = demoStore { return demo }

        // Try iCloud first
        if let data = ubiquitousStore.data(forKey: storageKey),
           let prefs = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            return prefs
        }

        // Fall back to UserDefaults for migration or offline use
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let prefs = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            // Migrate to iCloud
            prefs.save()
            return prefs
        }

        return UserPreferences()
    }

    func save() {
        if Self.demoStore != nil {
            Self.demoStore = self
            return
        }
        if let data = try? JSONEncoder().encode(self) {
            // Save to iCloud for sync
            Self.ubiquitousStore.set(data, forKey: Self.storageKey)
            Self.ubiquitousStore.synchronize()

            // Also save locally as backup
            UserDefaults.standard.set(data, forKey: Self.storageKey)

            // Save to App Group for Top Shelf extension
            UserDefaults(suiteName: ServerConfig.appGroupSuite)?.set(data, forKey: Self.storageKey)
        }
    }

    static func loadFromAppGroup() -> UserPreferences {
        guard let data = UserDefaults(suiteName: ServerConfig.appGroupSuite)?.data(forKey: storageKey),
              let prefs = try? JSONDecoder().decode(UserPreferences.self, from: data) else {
            return UserPreferences()
        }
        return prefs
    }

    /// Call this to start observing iCloud sync changes
    static func startObservingSync(onChange: @escaping () -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore,
            queue: .main
        ) { _ in
            onChange()
        }
    }
}
