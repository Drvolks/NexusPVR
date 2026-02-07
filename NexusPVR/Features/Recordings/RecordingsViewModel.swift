//
//  RecordingsViewModel.swift
//  nextpvr-apple-client
//
//  View model for recordings list
//

import SwiftUI
import Combine

enum RecordingsFilter: String, Identifiable {
    case completed = "Completed"
    case recording = "Recording"
    case scheduled = "Scheduled"

    var id: String { rawValue }
}

@MainActor
final class RecordingsViewModel: ObservableObject {
    @Published var completedRecordings: [Recording] = []
    @Published var activeRecordings: [Recording] = []
    @Published var scheduledRecordings: [Recording] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var filter: RecordingsFilter = .completed

    private let client: NextPVRClient

    init(client: NextPVRClient) {
        self.client = client
    }

    var hasActiveRecordings: Bool {
        !activeRecordings.isEmpty
    }

    var filteredRecordings: [Recording] {
        switch filter {
        case .completed:
            return completedRecordings.sorted { r1, r2 in
                guard let d1 = r1.startDate, let d2 = r2.startDate else { return false }
                return d1 > d2
            }
        case .recording:
            return activeRecordings.sorted { r1, r2 in
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

            let (completed, recording, scheduled) = try await client.getAllRecordings()
            completedRecordings = completed
            activeRecordings = recording
            scheduledRecordings = scheduled

            // If viewing recording tab but no active recordings, switch to completed
            if filter == .recording && activeRecordings.isEmpty {
                filter = .completed
            }

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
        activeRecordings.removeAll { $0.id == recording.id }
        scheduledRecordings.removeAll { $0.id == recording.id }
    }

    func playRecording(_ recording: Recording) async throws -> URL {
        try await client.recordingStreamURL(recordingId: recording.id)
    }
}
