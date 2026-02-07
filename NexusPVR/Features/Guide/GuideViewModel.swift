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

    func loadData(using client: NextPVRClient) async {
        // Yield to allow the view to finish rendering before modifying state
        await Task.yield()

        guard client.isConfigured else {
            error = "Server not configured"
            return
        }

        isLoading = true
        error = nil

        do {
            if !client.isAuthenticated {
                try await client.authenticate()
            }

            // Load channels first (required for listings)
            let loadedChannels = try await client.getChannels()
            let sortedChannels = loadedChannels.sorted { $0.number < $1.number }

            // Show channels immediately while loading listings
            channels = sortedChannels

            // Preload channel icons in background
            let iconURLs = sortedChannels.compactMap { client.channelIconURL(channelId: $0.id) }
            ImageCache.shared.preload(urls: iconURLs)

            // Load listings and recordings in parallel
            async let listingsTask = client.getAllListings(for: sortedChannels)
            async let recordingsTask = client.getAllRecordings()

            let (loadedListings, (completed, recording, scheduled)) = try await (listingsTask, recordingsTask)

            // Update recordings (didSet rebuilds O(1) lookup index)
            recordings = completed + recording + scheduled
            #if DEBUG
            for r in recordings {
                print("GuideVM: Recording id=\(r.id) name=\(r.name) status=\(r.status ?? "nil") epgEventId=\(r.epgEventId.map(String.init) ?? "nil") channelId=\(r.channelId.map(String.init) ?? "nil")")
            }
            #endif

            listings = loadedListings
            updateVisiblePrograms()
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

    func reloadRecordings(client: NextPVRClient) async {
        do {
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            recordings = completed + recording + scheduled
        } catch {
            // Silently fail - recordings indicator will update on next full reload
        }
    }
}
