//
//  SeriesInfo.swift
//  nextpvr-apple-client
//
//  Series information parsed from program metadata
//

import Foundation

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
