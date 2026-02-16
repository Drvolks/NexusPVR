//
//  GuideViewModel.swift
//  nextpvr-apple-client
//
//  View model for the TV guide/EPG
//

import SwiftUI
import Combine

@MainActor
final class GuideViewModel: ObservableObject {
    @Published var recordings: [Recording] = [] {
        didSet {
            recordingsByEventId = Dictionary(
                recordings.compactMap { r in r.epgEventId.map { ($0, r) } },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    @Published var isLoading = false
    @Published var hasLoaded = false
    @Published var error: String?

    @Published var selectedDate = Date()

    @Published var showChannelSearch: Bool = false
    @Published var channelSearchText: String = ""

    // O(1) lookup for recording status by program ID
    private var recordingsByEventId: [Int: Recording] = [:]

    // Cached sport detection results (avoids re-running regex per render)
    private var sportCache: [Int: Sport?] = [:]

    // Keyword-matched program IDs (O(1) lookup per cell)
    private(set) var keywordMatchedProgramIds: Set<Int> = []

    // Reference to EPGCache (set during loadData)
    weak var epgCache: EPGCache?

    var timelineStart: Date {
        let calendar = Calendar.current
        return calendar.startOfDay(for: selectedDate)
    }

    /// Channels to display in the guide (reads from EPGCache, filtered by search)
    /// Uses visibleChannels which starts with first 20, expands to all after EPG loads
    var channels: [Channel] {
        guard let cache = epgCache else { return [] }
        if channelSearchText.isEmpty {
            return cache.visibleChannels
        } else {
            return cache.filteredChannels(matching: channelSearchText)
        }
    }

    var hoursToShow: [Date] {
        var hours: [Date] = []
        let calendar = Calendar.current
        var current = timelineStart

        for _ in 0..<24 {
            hours.append(current)
            current = calendar.date(byAdding: .hour, value: 1, to: current) ?? current
        }
        return hours
    }

    /// Returns cached sport detection result for a program
    func detectedSport(for program: Program) -> Sport? {
        if let cached = sportCache[program.id] {
            return cached
        }
        let sport = SportDetector.detect(from: program)
        sportCache[program.id] = sport
        return sport
    }

    /// Compute keyword matches for programs of a specific channel
    func updateKeywordMatches(keywords: [String]) {
        guard !keywords.isEmpty, let cache = epgCache else {
            keywordMatchedProgramIds = []
            return
        }
        let lowercasedKeywords = keywords.map { $0.lowercased() }
        var matched = Set<Int>()
        for channel in channels {
            for program in cache.programs(for: channel.id, on: selectedDate) {
                let searchText = [
                    program.name,
                    program.subtitle ?? "",
                    program.desc ?? ""
                ].joined(separator: " ").lowercased()
                if lowercasedKeywords.contains(where: { searchText.contains($0) }) {
                    matched.insert(program.id)
                }
            }
        }
        keywordMatchedProgramIds = matched
    }

    func loadData(using client: PVRClient, epgCache: EPGCache) async {
        await Task.yield()

        self.epgCache = epgCache

        guard client.isConfigured else {
            error = "Server not configured"
            return
        }

        isLoading = true
        error = nil
        sportCache = [:]

        // Wait for EPGCache channels to be ready (may already be loaded by ContentView)
        while !epgCache.hasLoaded && epgCache.error == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if let cacheError = epgCache.error {
            self.error = cacheError
            isLoading = false
            hasLoaded = true
            return
        }

        showChannelSearch = epgCache.channels.count > 25

        do {
            // Load recordings
            let recordingsStart = CFAbsoluteTimeGetCurrent()
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            recordings = completed + recording + scheduled
            print("[Guide] Loaded \(recordings.count) recordings in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - recordingsStart) * 1000))ms")

            isLoading = false
            hasLoaded = true
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            hasLoaded = true
        }
    }

    /// Handle date navigation — ensure EPG data is cached for the new date
    func navigateToDate(using client: PVRClient) async {
        guard let cache = epgCache else { return }
        sportCache = [:]
        await cache.ensureDay(selectedDate, using: client)
        // Prefetch adjacent days in background
        Task {
            await cache.prefetchAdjacentDays(around: selectedDate, using: client)
        }
    }

    func programs(for channel: Channel) -> [Program] {
        epgCache?.epg[channel.id] ?? []
    }

    /// Lazily look up programs for a channel on the selected date from the cache
    func visiblePrograms(for channel: Channel) -> [Program] {
        guard let cache = epgCache else { return [] }
        return cache.programs(for: channel.id, on: selectedDate)
    }

    func programWidth(for program: Program, hourWidth: CGFloat, startTime: Date) -> CGFloat {
        let visibleStart = max(program.startDate, startTime)
        let visibleEnd = min(program.endDate, startTime.addingTimeInterval(24 * 3600))
        let duration = visibleEnd.timeIntervalSince(visibleStart)
        return max(CGFloat(duration / 3600) * hourWidth, 50)
    }

    func programOffset(for program: Program, hourWidth: CGFloat, startTime: Date) -> CGFloat {
        let visibleStart = max(program.startDate, startTime)
        let offset = visibleStart.timeIntervalSince(startTime)
        return CGFloat(offset / 3600) * hourWidth
    }

    func scrollToNow() {
        selectedDate = Date()
    }

    func previousDay() {
        selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
    }

    func nextDay() {
        selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
    }

    func isScheduledRecording(_ program: Program) -> Bool {
        recordingsByEventId[program.id] != nil
    }

    func recordingStatus(_ program: Program) -> RecordingStatus? {
        recordingsByEventId[program.id]?.recordingStatus
    }

    func recordingId(for program: Program) -> Int? {
        if let id = recordingsByEventId[program.id]?.id {
            return id
        }
        guard let channelId = program.channelId else { return nil }
        return findOverlappingRecording(channelId: channelId, programStart: program.startDate, programEnd: program.endDate)?.id
    }

    func activeRecordingId(for program: Program, channelId: Int) -> Int? {
        if let id = recordingsByEventId[program.id]?.id {
            return id
        }
        return findOverlappingRecording(channelId: channelId, programStart: program.startDate, programEnd: program.endDate)?.id
    }

    private func findOverlappingRecording(channelId: Int, programStart: Date, programEnd: Date) -> Recording? {
        for r in recordings {
            guard r.channelId == channelId else { continue }
            guard r.recordingStatus == .recording else { continue }
            guard let rStart = r.startDate, let rEnd = r.endDate else { continue }
            if rStart < programEnd && rEnd > programStart {
                return r
            }
        }
        return nil
    }

    func reloadRecordings(client: PVRClient) async {
        do {
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            recordings = completed + recording + scheduled
        } catch {
            // Silently fail - recordings indicator will update on next full reload
        }
    }
}
