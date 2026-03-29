//
//  AppState.swift
//  nextpvr-apple-client
//
//  Global application state
//

import SwiftUI
import Combine

struct RecordingsSeriesItem: Identifiable, Hashable {
    let name: String
    let count: Int

    var id: String { name }
}

enum Tab: String, Identifiable {
    case guide = "Guide"
    case recordings = "Recordings"
    case topics = "Topics"
    case calendar = "Calendar"
    case search = "Search"
    #if DISPATCHERPVR
    case stats = "Status"
    #endif
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .guide: return "calendar"
        case .topics: return "star.fill"
        case .calendar: return "calendar.badge.clock"
        case .search: return "magnifyingglass"
        case .recordings: return "recordingtape"
        #if DISPATCHERPVR
        case .stats: return "chart.bar.fill"
        #endif
        case .settings: return "gear"
        }
    }

    var label: String { rawValue }

    static var allCases: [Tab] {
        allCases(userLevel: 10)
    }

    static func allCases(userLevel: Int) -> [Tab] {
        var cases: [Tab] = [.guide]
        if userLevel >= 1 { cases.append(.recordings) }
        cases.append(contentsOf: [.topics, .search])
        #if DISPATCHERPVR
        if userLevel >= 1 { cases.append(.stats) }
        #endif
        cases.append(.settings)
        return cases
    }

    #if os(iOS)
    /// Tabs shown in the iOS collapsible nav bar (search is integrated into the bar itself)
    static func iOSTabs(userLevel: Int) -> [Tab] {
        var cases: [Tab] = [.guide]
        if userLevel >= 1 { cases.append(.recordings) }
        cases.append(contentsOf: [.topics, .calendar])
        #if DISPATCHERPVR
        if userLevel >= 1 { cases.append(.stats) }
        #endif
        cases.append(.settings)
        return cases
    }
    #endif

    #if os(macOS)
    /// Tabs shown in the macOS sidebar (search is integrated into the guide floating bar)
    static func macOSTabs(userLevel: Int) -> [Tab] {
        var cases: [Tab] = [.guide]
        if userLevel >= 1 { cases.append(.recordings) }
        cases.append(contentsOf: [.topics, .calendar])
        #if DISPATCHERPVR
        if userLevel >= 1 { cases.append(.stats) }
        #endif
        cases.append(.settings)
        return cases
    }
    #endif

    #if os(tvOS)
    /// Tabs shown in the tvOS sidebar
    static func tvOSTabs(userLevel: Int) -> [Tab] {
        var cases: [Tab] = [.guide]
        if userLevel >= 1 { cases.append(.recordings) }
        cases.append(.topics)
        #if DISPATCHERPVR
        if userLevel >= 1 { cases.append(.stats) }
        #endif
        cases.append(.settings)
        return cases
    }
    #endif
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: Tab = .guide
    @Published var searchQuery: String = ""
    @Published var guideChannelFilter: String = ""
    @Published var guideGroupFilter: Int? = nil
    @Published var isShowingPlayer = false

    #if os(iOS)
    /// Whether the floating bottom bar should be hidden (e.g. while scrolling down in the guide)
    @Published var isBottomBarHidden = false
    #endif

    // Topic picker state (shared between TopicsView and iOS nav bar)
    @Published var topicKeywords: [String] = []
    @Published var topicKeywordMatchCounts: [String: Int] = [:]
    @Published var selectedTopicKeyword: String = ""
    @Published var showingKeywordsEditor = false
    @Published var showingCalendar = false

    // Recordings filter state (shared between RecordingsListView and iOS nav bar)
    @Published var recordingsFilter: RecordingsFilter = .completed
    @Published var recordingsFilterUserOverride = false
    @Published var activeRecordingCount = 0
    @Published var recordingsSeriesItems: [RecordingsSeriesItem] = []
    @Published var recordingsSeriesIsLoading = false
    @Published var selectedRecordingsSeriesName: String = ""
    @Published var showingRecordingsSeriesList = false
    var recordingsHasActive: Bool { activeRecordingCount > 0 }
    var hasSelectedRecordingsSeries: Bool { !selectedRecordingsSeriesName.isEmpty }
    @Published var currentlyPlayingURL: URL?
    @Published var currentlyPlayingTitle: String?
    @Published var currentlyPlayingRecordingId: Int?
    @Published var currentlyPlayingResumePosition: Int?
    @Published var currentlyPlayingChannelId: Int?
    @Published var currentlyPlayingChannelName: String?
    @Published var currentlyPlayingIsRecordingInProgress = false

    // Navigation state
    @Published var selectedChannel: Channel?
    @Published var selectedProgram: Program?
    @Published var selectedRecording: Recording?
    #if os(tvOS)
    /// When true, the global tvOS escape handler must not move focus to the sidebar.
    @Published var tvosBlocksSidebarExitCommand = false
    /// Settings-specific exit orchestration for tvOS.
    @Published var tvosSettingsHasPopup = false
    @Published var tvosSettingsShowingEventLog = false
    @Published var tvosSettingsDismissPopupRequest = 0
    @Published var tvosSettingsDismissEventLogRequest = 0
    #endif

    // Alert state
    @Published var alertMessage: String?
    @Published var isShowingAlert = false

    #if DISPATCHERPVR
    // Active stream count for badge
    @Published var activeStreamCount = 0
    // M3U account error indicator for badge
    @Published var hasM3UErrors = false
    /// User role level from Dispatcharr (0=Streamer, 1=Standard, 10=Admin)
    @Published var userLevel: Int = 10
    #else
    /// NexusPVR users always have full access
    var userLevel: Int { 10 }
    #endif
    #if DISPATCHERPVR
    /// Whether the current user can create/modify/delete recordings
    var canManageRecordings: Bool { userLevel >= 10 }
    private var streamCountTask: Task<Void, Never>?

    func startStreamCountPolling(client: DispatcherClient) {
        stopStreamCountPolling()
        // Streamer users (output-only) have no access to proxy/m3u APIs
        guard !client.useOutputEndpoints else { return }
        streamCountTask = Task { [weak self] in
            while !Task.isCancelled {
                // Skip polling while player is active to reduce network/CPU during playback
                if self?.isShowingPlayer != true {
                    do {
                        let status = try await client.getProxyStatus()
                        let newCount = status.count ?? status.channels?.count ?? 0
                        self?.activeStreamCount = newCount
                    } catch {
                        // Silently ignore - badge just won't update
                    }
                    do {
                        let accounts = try await client.getM3UAccounts()
                        let activeAccounts = accounts.filter { $0.isActive && !$0.locked }
                        let hasErrors = activeAccounts.contains { $0.status != "success" }
                        self?.hasM3UErrors = hasErrors
                    } catch {
                        // Silently ignore
                    }
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

    #if !TOPSHELF_EXTENSION
    private var recordingsActivityTask: Task<Void, Never>?

    func startRecordingsActivityPolling(client: PVRClient) {
        stopRecordingsActivityPolling()
        recordingsActivityTask = Task { [weak self] in
            while !Task.isCancelled {
                // Skip polling while player is active to reduce network/CPU during playback
                if self?.isShowingPlayer != true {
                    await self?.refreshRecordingsActivity(client: client)
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopRecordingsActivityPolling() {
        recordingsActivityTask?.cancel()
        recordingsActivityTask = nil
    }

    func refreshRecordingsActivity(client: PVRClient) async {
        if !client.isConfigured {
            activeRecordingCount = 0
            return
        }
        do {
            if !client.isAuthenticated {
                try await client.authenticate()
            }
            let (_, recording, _) = try await client.getAllRecordings()
            activeRecordingCount = recording.count
        } catch {
            // Silently ignore transient errors; keep last known badge state.
        }
    }

    func refreshRecordingsSidebarData(client: PVRClient) async {
        if !client.isConfigured {
            activeRecordingCount = 0
            recordingsSeriesItems = []
            recordingsSeriesIsLoading = false
            return
        }

        recordingsSeriesIsLoading = true
        defer { recordingsSeriesIsLoading = false }

        do {
            if !client.isAuthenticated {
                try await client.authenticate()
            }
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            activeRecordingCount = recording.count

            let grouped = Dictionary(grouping: (completed + scheduled).filter { $0.seriesInfo != nil }) {
                $0.seriesInfo!.seriesName
            }
            recordingsSeriesItems = grouped
                .map { name, recordings in
                    RecordingsSeriesItem(name: name, count: recordings.count)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            // Keep previous values on transient failures.
        }
    }
    #endif

    func showAlert(_ message: String) {
        alertMessage = message
        isShowingAlert = true
    }

    func setRecordingsFilter(_ filter: RecordingsFilter, userInitiated: Bool) {
        recordingsFilter = filter
        selectedRecordingsSeriesName = ""
        showingRecordingsSeriesList = false
        if userInitiated {
            recordingsFilterUserOverride = true
        }
    }

    func selectRecordingsSeries(named seriesName: String, userInitiated: Bool) {
        selectedRecordingsSeriesName = seriesName
        showingRecordingsSeriesList = false
        if userInitiated {
            recordingsFilterUserOverride = true
        }
    }

    func showRecordingsSeriesMenu(userInitiated: Bool) {
        selectedRecordingsSeriesName = ""
        showingRecordingsSeriesList = true
        if userInitiated {
            recordingsFilterUserOverride = true
        }
    }

    func playStream(
        url: URL,
        title: String,
        recordingId: Int? = nil,
        resumePosition: Int? = nil,
        channelId: Int? = nil,
        channelName: String? = nil,
        isRecordingInProgress: Bool = false
    ) {
        #if DEBUG
        let effectiveURL: URL
        if UserDefaults.standard.bool(forKey: "debugStreamEnabled"),
           let debugURL = UserDefaults.standard.string(forKey: "debugStreamURL"),
           let override = URL(string: debugURL) {
            effectiveURL = override
            print("DEBUG: stream URL overridden to \(debugURL)")
        } else {
            effectiveURL = url
        }
        #else
        let effectiveURL = url
        #endif
        currentlyPlayingURL = effectiveURL
        currentlyPlayingTitle = title
        currentlyPlayingRecordingId = recordingId
        currentlyPlayingResumePosition = resumePosition
        currentlyPlayingChannelId = channelId
        currentlyPlayingChannelName = channelName
        currentlyPlayingIsRecordingInProgress = isRecordingInProgress
        isShowingPlayer = true
    }

    func playStream(url: URL, title: String, channelId: Int, channelName: String) {
        var history = WatchHistory.load()
        history.recordChannelPlay(channelId: channelId, channelName: channelName)
        history.save()
        playStream(
            url: url,
            title: title,
            recordingId: nil,
            resumePosition: nil,
            channelId: channelId,
            channelName: channelName
        )
    }

    func stopPlayback() {
        isShowingPlayer = false
        currentlyPlayingURL = nil
        currentlyPlayingTitle = nil
        currentlyPlayingRecordingId = nil
        currentlyPlayingResumePosition = nil
        currentlyPlayingChannelId = nil
        currentlyPlayingChannelName = nil
        currentlyPlayingIsRecordingInProgress = false
    }

    /// Dismiss the player UI without clearing playback state (used for PiP).
    func dismissPlayer() {
        isShowingPlayer = false
    }
}
