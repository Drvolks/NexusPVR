//
//  ChannelGroup.swift
//  nextpvr-apple-client
//
//  Channel group model
//

import Foundation

nonisolated struct ChannelGroup: Identifiable, Decodable, Sendable {
    let id: Int
    let name: String
}
