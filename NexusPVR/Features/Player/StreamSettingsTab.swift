//
//  StreamSettingsTab.swift
//  nextpvr-apple-client
//
//  Player stream settings tab options
//

import Foundation

enum StreamSettingsTab: String, CaseIterable {
    case video = "Video"
    case audio = "Audio"
    case subtitles = "Subs"

    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "speaker.wave.2"
        case .subtitles: return "captions.bubble"
        }
    }
}
