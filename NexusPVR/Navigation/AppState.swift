//
//  AppState.swift
//  nextpvr-apple-client
//
//  Global application state
//

import SwiftUI
import Combine

enum Tab: String, Identifiable {
    case guide = "Guide"
    case recordings = "Recordings"
    case topics = "Topics"
    #if DISPATCHERPVR
    case stats = "Status"
    #endif
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .guide: return "calendar"
        case .topics: return "star.fill"
        case .recordings: return "recordingtape"
        #if DISPATCHERPVR
        case .stats: return "chart.bar.fill"
        #endif
        case .settings: return "gear"
        }
    }

    var label: String { rawValue }

    static var allCases: [Tab] {
        var cases: [Tab] = [.guide, .recordings, .topics]
        #if DISPATCHERPVR
        cases.append(.stats)
        #endif
        cases.append(.settings)
        return cases
    }
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

    #if DISPATCHERPVR
    // Active stream count for badge
    @Published var activeStreamCount = 0
    private var streamCountTask: Task<Void, Never>?

    func startStreamCountPolling(client: DispatcherClient) {
        stopStreamCountPolling()
        streamCountTask = Task {
            while !Task.isCancelled {
                do {
                    let status = try await client.getProxyStatus()
                    activeStreamCount = status.count ?? status.channels?.count ?? 0
                } catch {
                    // Silently ignore - badge just won't update
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopStreamCountPolling() {
        streamCountTask?.cancel()
        streamCountTask = nil
    }
    #endif

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
