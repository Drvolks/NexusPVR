//
//  ChannelProfile.swift
//  nextpvr-apple-client
//
//  Channel profile model
//

import Foundation

nonisolated struct ChannelProfile: Identifiable, Decodable, Sendable {
    let id: Int
    let name: String
    let channels: [Int]
}
