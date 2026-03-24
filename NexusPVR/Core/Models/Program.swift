//
//  Program.swift
//  nextpvr-apple-client
//
//  NextPVR EPG program model
//

import Foundation

// MARK: - Series Info

nonisolated struct SeriesInfo: Hashable, Sendable {
    let season: Int
    let episode: Int
    /// The series name (program name with SXXEXX pattern stripped)
    let seriesName: String

    var displayString: String {
        "Season \(season) Episode \(episode)"
    }

    var shortDisplayString: String {
        String(format: "S%02dE%02d", season, episode)
    }

    /// Parse SXXEXX pattern from a string. Returns the match and range if found.
    private static let pattern = try! NSRegularExpression(pattern: #"[Ss](\d{1,2})[Ee](\d{1,2})"#)

    /// Strip SXXEXX pattern and surrounding separators from a string
    static func stripPattern(from string: String) -> String {
        let range = NSRange(string.startIndex..., in: string)
        let result = pattern.stringByReplacingMatches(in: string, range: range, withTemplate: "")
        return result
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract SeriesInfo from program/recording fields
    static func parse(name: String, subtitle: String? = nil, desc: String? = nil) -> SeriesInfo? {
        // Check subtitle first, then name, then description
        let candidates = [subtitle, name, desc].compactMap { $0 }
        for candidate in candidates {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let match = pattern.firstMatch(in: candidate, range: range),
               let seasonRange = Range(match.range(at: 1), in: candidate),
               let episodeRange = Range(match.range(at: 2), in: candidate),
               let season = Int(candidate[seasonRange]),
               let episode = Int(candidate[episodeRange]) {
                // Series name: strip SXXEXX from name if present, otherwise use name as-is
                let seriesName = stripPattern(from: name)
                    .isEmpty ? name : stripPattern(from: name)
                return SeriesInfo(season: season, episode: episode, seriesName: seriesName)
            }
        }
        return nil
    }
}

nonisolated struct Program: Identifiable, Decodable, Hashable, Sendable {
    let id: Int
    let name: String
    let subtitle: String?
    let desc: String?
    let start: Int // Unix timestamp
    let end: Int   // Unix timestamp
    let genres: [String]?
    let channelId: Int?
    let season: Int?
    let episode: Int?

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

    var seriesInfo: SeriesInfo? {
        if let season, let episode, season > 0, episode > 0 {
            return SeriesInfo(season: season, episode: episode, seriesName: name)
        }
        return SeriesInfo.parse(name: name, subtitle: subtitle, desc: desc)
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
        case season
        case episode
    }

    init(id: Int, name: String, subtitle: String?, desc: String?, start: Int, end: Int, genres: [String]?, channelId: Int?, season: Int? = nil, episode: Int? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.desc = desc
        self.start = start
        self.end = end
        self.genres = genres
        self.channelId = channelId
        self.season = season
        self.episode = episode
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

        season = try container.decodeIfPresent(Int.self, forKey: .season)
        episode = try container.decodeIfPresent(Int.self, forKey: .episode)
    }
}

nonisolated struct ProgramListingsResponse: Decodable {
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
