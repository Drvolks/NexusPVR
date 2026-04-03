//
//  WatchedChannel.swift
//  PVR Client
//
//  Recently watched channel model
//

import Foundation

nonisolated struct WatchedChannel: Codable, Equatable {
    let channelId: Int
    let channelName: String
}
