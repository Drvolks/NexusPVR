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
    @Published var recordings: [Recording] = []
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

            let (loadedListings, (completed, scheduled)) = try await (listingsTask, recordingsTask)

            // Update recordings with O(1) lookup index
            let allRecordings = completed + scheduled
            recordings = allRecordings
            recordingsByEventId = Dictionary(
                allRecordings.compactMap { r in r.epgEventId.map { ($0, r) } },
                uniquingKeysWith: { first, _ in first }
            )

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
}
