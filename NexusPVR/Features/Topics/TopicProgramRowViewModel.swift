//
//  TopicProgramRowViewModel.swift
//  NexusPVR
//
//  Shared state and logic for TopicProgramRow (iOS/macOS) and TopicProgramRowTV (tvOS)
//

import SwiftUI
import Combine

private func normalizeProgramName(_ name: String) -> String {
    name
        .replacingOccurrences(of: " ᴺᵉʷ", with: "")
        .lowercased()
        .split(separator: " ")
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
}

@MainActor
final class TopicProgramRowViewModel: ObservableObject {
    @Published var isScheduled = false
    @Published var isRecording = false
    @Published var existingRecordingId: Int?
    @Published var isProcessing = false
    @Published var existingRecording: Recording?
    @Published var earlierScheduled: Recording?

    let program: Program
    let channel: Channel

    init(program: Program, channel: Channel) {
        self.program = program
        self.channel = channel
    }

    var programScheduleText: String {
        let start = program.startDate.formatted(date: .abbreviated, time: .shortened)
        let end = program.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) - \(end)"
    }

    func checkIfScheduled(using client: PVRClient) async {
        do {
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            let allRecordings = completed + recording + scheduled

            if let rec = allRecordings.first(where: { $0.epgEventId == program.id }) {
                isScheduled = true
                isRecording = rec.recordingStatus == .recording
                existingRecordingId = rec.id
            }

            let cutoff = Date().addingTimeInterval(-48 * 3600)
            if let existing = completed.first(where: { recording in
                normalizeProgramName(recording.name) == normalizeProgramName(program.name) &&
                recording.recordingStatus == .ready &&
                (recording.startDate ?? .distantPast) > cutoff
            }) {
                existingRecording = existing
            }

            if let earlier = scheduled.first(where: { recording in
                normalizeProgramName(recording.name) == normalizeProgramName(program.name) &&
                recording.epgEventId != program.id &&
                (recording.startTime ?? 0) < program.start &&
                recording.recordingStatus == .pending
            }) {
                earlierScheduled = earlier
            }
        } catch {
            // Silently fail
        }
    }

    func toggleRecording(using client: PVRClient, onChanged: (() -> Void)?) {
        isProcessing = true
        Task {
            do {
                if isScheduled, let recordingId = existingRecordingId {
                    try await client.cancelRecording(recordingId: recordingId)
                    isScheduled = false
                    existingRecordingId = nil
                } else {
                    try await client.scheduleRecording(eventId: program.id)
                    isScheduled = true
                    await checkIfScheduled(using: client)
                }
                isProcessing = false
                onChanged?()
            } catch {
                isProcessing = false
            }
        }
    }

    func playExistingRecording(_ recording: Recording, using client: PVRClient, appState: AppState) {
        Task {
            do {
                let url = try await client.recordingStreamURL(recordingId: recording.id)
                appState.playStream(
                    url: url,
                    title: recording.name,
                    recordingId: recording.id,
                    resumePosition: recording.playbackPosition
                )
            } catch {
                // Silently fail
            }
        }
    }
}
