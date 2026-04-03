//
//  RecurringRecording.swift
//  nextpvr-apple-client
//
//  Recurring recording model
//

import Foundation

nonisolated struct RecurringRecording: Identifiable, Decodable {
    let id: Int
    let name: String
    let channelID: Int?
    let channel: String?
    let enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, channelID, channel, enabled
        case epgTitle
    }

    init(id: Int, name: String, channelID: Int?, channel: String?, enabled: Bool?) {
        self.id = id
        self.name = name
        self.channelID = channelID
        self.channel = channel
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        // Try epgTitle first, then name
        if let title = try? container.decode(String.self, forKey: .epgTitle) {
            name = title
        } else {
            name = try container.decode(String.self, forKey: .name)
        }
        channelID = try container.decodeIfPresent(Int.self, forKey: .channelID)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    }
}
