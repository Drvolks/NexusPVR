//
//  WatchHistory.swift
//  PVR Client
//
//  Tracks recently watched channels for Top Shelf fallback.
//

import Foundation

struct WatchedChannel: Codable, Equatable {
    let channelId: Int
    let channelName: String
}

struct WatchHistory: Codable {
    var recentChannels: [WatchedChannel] = []

    #if DISPATCHERPVR
    private static let storageKey = "WatchHistory_Dispatcharr"
    #else
    private static let storageKey = "WatchHistory_NextPVR"
    #endif

    mutating func recordChannelPlay(channelId: Int, channelName: String) {
        recentChannels.removeAll { $0.channelId == channelId }
        recentChannels.insert(WatchedChannel(channelId: channelId, channelName: channelName), at: 0)
        if recentChannels.count > 4 {
            recentChannels = Array(recentChannels.prefix(4))
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
        UserDefaults(suiteName: ServerConfig.appGroupSuite)?.set(data, forKey: Self.storageKey)
    }

    static func load() -> WatchHistory {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let history = try? JSONDecoder().decode(WatchHistory.self, from: data) {
            return history
        }
        return WatchHistory()
    }

    nonisolated static func loadFromAppGroup() -> WatchHistory {
        guard let data = UserDefaults(suiteName: ServerConfig.appGroupSuite)?.data(forKey: storageKey),
              let history = try? JSONDecoder().decode(WatchHistory.self, from: data) else {
            return WatchHistory()
        }
        return history
    }
}
