//
//  Program.swift
//  nextpvr-apple-client
//
//  NextPVR EPG program model
//

import Foundation

struct Program: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let subtitle: String?
    let desc: String?
    let start: Int // Unix timestamp
    let end: Int   // Unix timestamp
    let genres: [String]?
    let channelId: Int?

    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(start))
    }

    var endDate: Date {
        Date(timeIntervalSince1970: TimeInterval(end))
    }

    var duration: TimeInterval {
        TimeInterval(end - start)
    }

    var durationMinutes: Int {
        Int(duration / 60)
    }

    var isCurrentlyAiring: Bool {
        let now = Date()
        return startDate <= now && endDate > now
    }

    var hasEnded: Bool {
        Date() > endDate
    }

    func progress(at date: Date = Date()) -> Double {
        guard isCurrentlyAiring else { return hasEnded ? 1.0 : 0.0 }
        guard duration > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(startDate)
        return min(max(elapsed / duration, 0), 1)
    }

    enum CodingKeys: String, CodingKey {
        case id, eventId = "event_id"
        case name, title
        case subtitle
        case desc, description
        case start, startTime = "start_time"
        case end, endTime = "end_time"
        case genres
        case channelId, channel_id
    }

    init(id: Int, name: String, subtitle: String?, desc: String?, start: Int, end: Int, genres: [String]?, channelId: Int?) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.desc = desc
        self.start = start
        self.end = end
        self.genres = genres
        self.channelId = channelId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // ID: try event_id first, then id
        if let eventId = try? container.decode(Int.self, forKey: .eventId) {
            id = eventId
        } else {
            id = try container.decode(Int.self, forKey: .id)
        }

        // Name: try title first, then name
        if let title = try? container.decode(String.self, forKey: .title) {
            name = title
        } else {
            name = try container.decode(String.self, forKey: .name)
        }

        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)

        // Description: try description first, then desc
        if let description = try? container.decode(String.self, forKey: .description) {
            desc = description
        } else {
            desc = try container.decodeIfPresent(String.self, forKey: .desc)
        }

        // Start time
        if let startTime = try? container.decode(Int.self, forKey: .startTime) {
            start = startTime
        } else {
            start = try container.decode(Int.self, forKey: .start)
        }

        // End time
        if let endTime = try? container.decode(Int.self, forKey: .endTime) {
            end = endTime
        } else {
            end = try container.decode(Int.self, forKey: .end)
        }

        genres = try container.decodeIfPresent([String].self, forKey: .genres)

        if let chId = try? container.decode(Int.self, forKey: .channel_id) {
            channelId = chId
        } else {
            channelId = try container.decodeIfPresent(Int.self, forKey: .channelId)
        }
    }
}

struct ProgramListingsResponse: Decodable {
    let listings: [Program]?
}

extension Program {
    static var preview: Program {
        Program(
            id: 12345,
            name: "Sample Show",
            subtitle: "Episode Title",
            desc: "This is a sample program description for preview purposes.",
            start: Int(Date().timeIntervalSince1970),
            end: Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
            genres: ["Drama", "Action"],
            channelId: 1
        )
    }
}
