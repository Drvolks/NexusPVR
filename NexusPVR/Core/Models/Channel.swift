//
//  Channel.swift
//  nextpvr-apple-client
//
//  NextPVR channel model
//

import Foundation

nonisolated struct Channel: Identifiable, Decodable, Hashable, Sendable {
    let id: Int
    let name: String
    let number: Int
    let hasIcon: Bool
    let streamURL: String?
    let groupId: Int?

    enum CodingKeys: String, CodingKey {
        case id = "channelId"
        case name = "channelName"
        case number = "channelNumber"
        case hasIcon = "channelIcon"
        case streamURL = "channelDetails"
    }

    init(id: Int, name: String, number: Int, hasIcon: Bool = false, streamURL: String? = nil, groupId: Int? = nil) {
        self.id = id
        self.name = name
        self.number = number
        self.hasIcon = hasIcon
        self.streamURL = streamURL
        self.groupId = groupId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        hasIcon = try container.decodeIfPresent(Bool.self, forKey: .hasIcon) ?? false
        streamURL = try container.decodeIfPresent(String.self, forKey: .streamURL)?.trimmingCharacters(in: .whitespaces)
        groupId = nil
    }

    func iconURL(baseURL: String) -> URL? {
        URL(string: "\(baseURL)/service?method=channel.icon&channel_id=\(id)")
    }
}

nonisolated struct ChannelProfile: Identifiable, Decodable, Sendable {
    let id: Int
    let name: String
    let channels: [Int]
}

nonisolated struct ChannelGroup: Identifiable, Decodable, Sendable {
    let id: Int
    let name: String
}

nonisolated struct ChannelListResponse: Decodable {
    let channels: [Channel]?
}
