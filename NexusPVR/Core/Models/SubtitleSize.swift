//
//  SubtitleSize.swift
//  nextpvr-apple-client
//
//  Subtitle size options
//

import Foundation

enum SubtitleSize: String, Codable, CaseIterable {
    case small
    case medium
    case large
    case extraLarge

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    var fontSize: CGFloat {
        #if os(tvOS)
        switch self {
        case .small: return 40
        case .medium: return 50
        case .large: return 65
        case .extraLarge: return 80
        }
        #else
        switch self {
        case .small: return 16
        case .medium: return 20
        case .large: return 26
        case .extraLarge: return 32
        }
        #endif
    }
}
