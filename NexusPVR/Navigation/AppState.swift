//
//  AppState.swift
//  nextpvr-apple-client
//
//  Global application state
//

import SwiftUI
import Combine

enum Tab: String, CaseIterable, Identifiable {
    case guide = "Guide"
    case recordings = "Recordings"
    case topics = "Topics"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .guide: return "calendar"
        case .topics: return "star.fill"
        case .recordings: return "recordingtape"
        case .settings: return "gear"
        }
    }

    var label: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: Tab = .guide
    @Published var isShowingPlayer = false
    @Published var currentlyPlayingURL: URL?
    @Published var currentlyPlayingTitle: String?
    @Published var currentlyPlayingRecordingId: Int?
    @Published var currentlyPlayingResumePosition: Int?

    // Navigation state
    @Published var selectedChannel: Channel?
    @Published var selectedProgram: Program?
    @Published var selectedRecording: Recording?

    // Alert state
    @Published var alertMessage: String?
    @Published var isShowingAlert = false

    func showAlert(_ message: String) {
        alertMessage = message
        isShowingAlert = true
    }

    func playStream(url: URL, title: String, recordingId: Int? = nil, resumePosition: Int? = nil) {
        currentlyPlayingURL = url
        currentlyPlayingTitle = title
        currentlyPlayingRecordingId = recordingId
        currentlyPlayingResumePosition = resumePosition
        isShowingPlayer = true
    }

    func stopPlayback() {
        isShowingPlayer = false
        currentlyPlayingURL = nil
        currentlyPlayingTitle = nil
        currentlyPlayingRecordingId = nil
        currentlyPlayingResumePosition = nil
    }
}
