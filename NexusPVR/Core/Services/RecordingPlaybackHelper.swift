//
//  RecordingPlaybackHelper.swift
//  NexusPVR
//
//  Shared recording playback logic used by RecordingsListView and RecordingDetailView
//

import Foundation

@MainActor
enum RecordingPlaybackHelper {
    static func play(
        recording: Recording,
        using client: PVRClient,
        appState: AppState,
        dismiss: (() -> Void)? = nil
    ) async throws {
        let url = try await client.recordingStreamURL(recordingId: recording.id)
        appState.playStream(
            url: url,
            title: recording.name,
            recordingId: recording.id,
            resumePosition: recording.playbackPosition,
            isRecordingInProgress: recording.recordingStatus == .recording
        )
        dismiss?()
    }

    static func playFromBeginning(
        recording: Recording,
        using client: PVRClient,
        appState: AppState,
        dismiss: (() -> Void)? = nil
    ) async throws {
        try await client.setRecordingPosition(recordingId: recording.id, positionSeconds: 0)
        let url = try await client.recordingStreamURL(recordingId: recording.id)
        appState.playStream(
            url: url,
            title: recording.name,
            recordingId: recording.id,
            resumePosition: 0,
            isRecordingInProgress: recording.recordingStatus == .recording
        )
        NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
        dismiss?()
    }

    static func playLive(
        recording: Recording,
        using client: PVRClient,
        appState: AppState,
        dismiss: (() -> Void)? = nil
    ) async throws {
        guard let channelId = recording.channelId else { return }
        let url = try await client.liveStreamURL(channelId: channelId)
        appState.playStream(
            url: url,
            title: recording.name,
            channelId: channelId,
            channelName: recording.channel ?? "Channel \(channelId)"
        )
        dismiss?()
    }
}
