//
//  UserPreferences.swift
//  nextpvr-apple-client
//
//  User preferences and settings - synced via iCloud
//

import Foundation

nonisolated struct UserPreferences: Codable {
    var keywords: [String] = []
    var seekBackwardSeconds: Int = 10
    var seekForwardSeconds: Int = 30
    var audioChannels: String = "auto"
    var tvosGPUAPI: GPUAPI = .pixelbuffer
    var iosGPUAPI: GPUAPI = .pixelbuffer
    var macosGPUAPI: GPUAPI = .pixelbuffer
    var subtitleMode: SubtitleMode = .manual
    var subtitleSize: SubtitleSize = .medium
    var subtitleBackground: Bool = true
    var preferredSubtitleLanguage: String? = nil
    var updatedAt: Date = .distantPast

    /// The GPU API for the current platform.
    var currentGPUAPI: GPUAPI {
        #if os(tvOS)
        tvosGPUAPI
        #elseif os(macOS)
        macosGPUAPI
        #else
        iosGPUAPI
        #endif
    }

    // Migration: keep old property for decoding existing data
    private enum CodingKeys: String, CodingKey {
        case keywords
        case seekBackwardSeconds
        case seekForwardSeconds
        case seekTimeSeconds // legacy
        case audioChannels
        case tvosGPUAPI
        case iosGPUAPI
        case macosGPUAPI
        case subtitleMode
        case subtitleSize
        case subtitleBackground
        case preferredSubtitleLanguage
        case updatedAt
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
        tvosGPUAPI = try container.decodeIfPresent(GPUAPI.self, forKey: .tvosGPUAPI) ?? .pixelbuffer
        iosGPUAPI = try container.decodeIfPresent(GPUAPI.self, forKey: .iosGPUAPI) ?? .pixelbuffer
        macosGPUAPI = try container.decodeIfPresent(GPUAPI.self, forKey: .macosGPUAPI) ?? .pixelbuffer
        subtitleMode = try container.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode) ?? .manual
        subtitleSize = try container.decodeIfPresent(SubtitleSize.self, forKey: .subtitleSize) ?? .medium
        subtitleBackground = try container.decodeIfPresent(Bool.self, forKey: .subtitleBackground) ?? true
        preferredSubtitleLanguage = try container.decodeIfPresent(String.self, forKey: .preferredSubtitleLanguage)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keywords, forKey: .keywords)
        try container.encode(seekBackwardSeconds, forKey: .seekBackwardSeconds)
        try container.encode(seekForwardSeconds, forKey: .seekForwardSeconds)
        try container.encode(audioChannels, forKey: .audioChannels)
        try container.encode(tvosGPUAPI, forKey: .tvosGPUAPI)
        try container.encode(iosGPUAPI, forKey: .iosGPUAPI)
        try container.encode(macosGPUAPI, forKey: .macosGPUAPI)
        try container.encode(subtitleMode, forKey: .subtitleMode)
        try container.encode(subtitleSize, forKey: .subtitleSize)
        try container.encode(subtitleBackground, forKey: .subtitleBackground)
        try container.encodeIfPresent(preferredSubtitleLanguage, forKey: .preferredSubtitleLanguage)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static let storageKey = "UserPreferences"
    private static let ubiquitousStore = NSUbiquitousKeyValueStore.default

    /// In-memory store for demo mode — when set, load/save bypass persistence
    nonisolated(unsafe) static var demoStore: UserPreferences?

    static func load() -> UserPreferences {
        if let demo = demoStore { return demo }

        let cloudPrefs = ubiquitousStore.data(forKey: storageKey).flatMap(decode)
        let localPrefs = UserDefaults.standard.data(forKey: storageKey).flatMap(decode)

        if let prefs = resolvePersistence(local: localPrefs, cloud: cloudPrefs) {
            persist(prefs)
            return prefs
        }

        return UserPreferences()
    }

    func save() {
        if Self.demoStore != nil {
            Self.demoStore = self
            return
        }
        var prefs = self
        prefs.updatedAt = Date()
        Self.persist(prefs)
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

    private static func decode(_ data: Data) -> UserPreferences? {
        try? JSONDecoder().decode(UserPreferences.self, from: data)
    }

    static func resolvePersistence(local: UserPreferences?, cloud: UserPreferences?) -> UserPreferences? {
        switch (local, cloud) {
        case let (local?, cloud?):
            if local.updatedAt == .distantPast && cloud.updatedAt == .distantPast {
                return local
            }
            return local.updatedAt >= cloud.updatedAt ? local : cloud
        case let (local?, nil):
            return local
        case let (nil, cloud?):
            return cloud
        case (nil, nil):
            return nil
        }
    }

    private static func persist(_ prefs: UserPreferences) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }

        // Save to iCloud for sync
        ubiquitousStore.set(data, forKey: storageKey)
        ubiquitousStore.synchronize()

        // Also save locally as backup
        UserDefaults.standard.set(data, forKey: storageKey)

        // Save to App Group for Top Shelf extension
        UserDefaults(suiteName: ServerConfig.appGroupSuite)?.set(data, forKey: storageKey)
    }
}
