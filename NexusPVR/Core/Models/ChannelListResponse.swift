//
//  ChannelListResponse.swift
//  nextpvr-apple-client
//
//  Channel list API response
//

import Foundation

nonisolated struct ChannelListResponse: Decodable {
    let channels: [Channel]?
}
