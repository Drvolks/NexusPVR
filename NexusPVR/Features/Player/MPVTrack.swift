//
//  MPVTrack.swift
//  nextpvr-apple-client
//
//  MPV track model for audio/video/subtitle selection
//

import Foundation

struct MPVTrack: Identifiable, Equatable {
    let id: Int
    let type: String       // "video", "audio", "sub"
    let title: String?
    let lang: String?
    let codec: String?
    let channels: String?  // audio only
    let bitrate: Int?      // demux-bitrate
    let isSelected: Bool

    var displayName: String {
        var parts: [String] = []
        if let lang = lang, !lang.isEmpty {
            parts.append(Locale.current.localizedString(forLanguageCode: lang) ?? lang)
        }
        if let title = title, !title.isEmpty {
            parts.append(title)
        }
        if parts.isEmpty {
            parts.append("Track \(id)")
        }
        return parts.joined(separator: " - ")
    }

    var audioDetail: String {
        var parts: [String] = []
        if let codec = codec { parts.append(codec.uppercased()) }
        if let ch = channels, let n = Int(ch) {
            switch n {
            case 1: parts.append("Mono")
            case 2: parts.append("Stereo")
            case 6: parts.append("5.1")
            case 8: parts.append("7.1")
            default: parts.append("\(n)ch")
            }
        }
        if let br = bitrate, br > 0 {
            parts.append("\(br / 1000) kbps")
        }
        return parts.joined(separator: " · ")
    }
}
