//
//  PlayerStats.swift
//  nextpvr-apple-client
//
//  MPV playback statistics
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
