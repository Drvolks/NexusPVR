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
    @Published var channels: [Channel] = []
    @Published var listings = [Int: [Program]]()
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

    @Published var selectedDate = Date() {
        didSet {
            updateVisiblePrograms()
        }
    }

    // Pre-computed visible programs for current date (O(1) lookup per channel)
    @Published private(set) var visibleProgramsByChannel: [Int: [Program]] = [:]

    // O(1) lookup for recording status by program ID
    private var recordingsByEventId: [Int: Recording] = [:]

    // Cached sport detection results (avoids re-running regex per render)
    private var sportCache: [Int: Sport?] = [:]

    // Pre-computed keyword-matched program IDs (O(1) lookup per cell)
    private(set) var keywordMatchedProgramIds: Set<Int> = []

    var timelineStart: Date {
        let calendar = Calendar.current
        // Start at midnight (00:00) of the selected day
        return calendar.startOfDay(for: selectedDate)
    }

    init() {
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

    /// Pre-compute visible programs for all channels for the current date
    private func updateVisiblePrograms() {
        let start = timelineStart
        let end = start.addingTimeInterval(24 * 3600)

        var result: [Int: [Program]] = [:]
        for (channelId, programs) in listings {
            result[channelId] = programs.filter { program in
                program.endDate > start && program.startDate < end
            }
        }
        visibleProgramsByChannel = result
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

    /// Pre-compute keyword matches for all visible programs
    func updateKeywordMatches(keywords: [String]) {
        guard !keywords.isEmpty else {
            keywordMatchedProgramIds = []
            return
        }
        let lowercasedKeywords = keywords.map { $0.lowercased() }
        var matched = Set<Int>()
        for programs in visibleProgramsByChannel.values {
            for program in programs {
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

    func loadData(using client: PVRClient) async {
        // Yield to allow the view to finish rendering before modifying state
        await Task.yield()

        guard client.isConfigured else {
            error = "Server not configured"
            return
        }

        isLoading = true
        error = nil
        sportCache = [:]

        do {
            if !client.isAuthenticated {
                try await client.authenticate()
            }

            // Load channels first (required for listings)
            let loadedChannels = try await client.getChannels()
            let sortedChannels = loadedChannels.sorted { $0.number < $1.number }

            // Show channels immediately while loading listings
            channels = sortedChannels

            // Preload channel icons in background (throttled)
            let iconURLs = sortedChannels.compactMap { client.channelIconURL(channelId: $0.id) }
            ImageCache.shared.preload(urls: iconURLs)

            // Load recordings in parallel with first batch of listings
            let recordingsTask = Task {
                try await client.getAllRecordings()
            }

            // Fetch listings progressively in batches
            let batchSize = 50
            for batchStart in stride(from: 0, to: sortedChannels.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, sortedChannels.count)
                let batch = Array(sortedChannels[batchStart..<batchEnd])

                let batchListings = try await client.getAllListings(for: batch)

                // Merge batch results into listings and update visible programs
                for (channelId, programs) in batchListings {
                    listings[channelId] = programs
                }
                updateVisiblePrograms()

                // After first batch, mark as loaded so UI shows content
                if !hasLoaded {
                    hasLoaded = true
                    isLoading = false
                }
            }

            // Await recordings
            let (completed, recording, scheduled) = try await recordingsTask.value
            recordings = completed + recording + scheduled
            #if DEBUG
            for r in recordings {
                print("GuideVM: Recording id=\(r.id) name=\(r.name) status=\(r.status ?? "nil") epgEventId=\(r.epgEventId.map(String.init) ?? "nil") channelId=\(r.channelId.map(String.init) ?? "nil")")
            }
            #endif

            isLoading = false
            hasLoaded = true
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            hasLoaded = true
        }
    }

    func programs(for channel: Channel) -> [Program] {
        listings[channel.id] ?? []
    }

    /// Returns cached visible programs for the current date (O(1) lookup)
    func visiblePrograms(for channel: Channel) -> [Program] {
        visibleProgramsByChannel[channel.id] ?? []
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
        // Try direct event ID match first
        if let id = recordingsByEventId[program.id]?.id {
            return id
        }
        // Fallback: find a recording on the same channel that overlaps this program's time
        guard let channelId = program.channelId else { return nil }
        return findOverlappingRecording(channelId: channelId, programStart: program.startDate, programEnd: program.endDate)?.id
    }

    /// Check if a program has a recording, including fallback by channel/time overlap
    func activeRecordingId(for program: Program, channelId: Int) -> Int? {
        if let id = recordingsByEventId[program.id]?.id {
            #if DEBUG
            print("GuideVM: activeRecordingId matched by epgEventId for '\(program.name)' -> \(id)")
            #endif
            return id
        }
        let match = findOverlappingRecording(channelId: channelId, programStart: program.startDate, programEnd: program.endDate)
        #if DEBUG
        if let m = match {
            print("GuideVM: activeRecordingId matched by channel/time for '\(program.name)' -> \(m.id)")
        } else {
            let inProgress = recordings.filter { $0.recordingStatus == .recording }
            print("GuideVM: activeRecordingId NO match for '\(program.name)' programId=\(program.id) channelId=\(channelId) isAiring=\(program.isCurrentlyAiring) recordingsWithRecordingStatus=\(inProgress.count) totalRecordings=\(recordings.count)")
        }
        #endif
        return match?.id
    }

    /// Find a recording in progress that overlaps the given time range on the given channel
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
