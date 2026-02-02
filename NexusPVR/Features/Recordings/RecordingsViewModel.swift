//
//  RecordingsViewModel.swift
//  nextpvr-apple-client
//
//  View model for recordings list
//

import SwiftUI
import Combine

enum RecordingsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case completed = "Completed"
    case scheduled = "Scheduled"

    var id: String { rawValue }
}

@MainActor
final class RecordingsViewModel: ObservableObject {
    @Published var completedRecordings: [Recording] = []
    @Published var scheduledRecordings: [Recording] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var filter: RecordingsFilter = .completed

    private let client: NextPVRClient

    init(client: NextPVRClient) {
        self.client = client
    }

    var filteredRecordings: [Recording] {
        switch filter {
        case .all:
            return (completedRecordings + scheduledRecordings).sorted { r1, r2 in
                guard let d1 = r1.startDate, let d2 = r2.startDate else { return false }
                return d1 > d2
            }
        case .completed:
            return completedRecordings.sorted { r1, r2 in
                guard let d1 = r1.startDate, let d2 = r2.startDate else { return false }
                return d1 > d2
            }
        case .scheduled:
            return scheduledRecordings.sorted { r1, r2 in
                guard let d1 = r1.startDate, let d2 = r2.startDate else { return false }
                return d1 < d2
            }
        }
    }

    func loadRecordings() async {
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

            let (completed, scheduled) = try await client.getAllRecordings()
            completedRecordings = completed
            scheduledRecordings = scheduled
            #if DEBUG
            print("RecordingsViewModel: Loaded \(completedRecordings.count) completed, \(scheduledRecordings.count) scheduled")
            print("RecordingsViewModel: Filtered recordings count: \(filteredRecordings.count)")
            #endif
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func deleteRecording(_ recording: Recording) async throws {
        try await client.cancelRecording(recordingId: recording.id)

        // Remove from local lists
        completedRecordings.removeAll { $0.id == recording.id }
        scheduledRecordings.removeAll { $0.id == recording.id }
    }

    func playRecording(_ recording: Recording) async throws -> URL {
        try await client.recordingStreamURL(recordingId: recording.id)
    }
}
