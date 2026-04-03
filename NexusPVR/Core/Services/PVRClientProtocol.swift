//
//  PVRClientProtocol.swift
//  PVR Client
//
//  Shared protocol for PVR API clients
//

import Foundation

@MainActor
protocol PVRClientProtocol: ObservableObject {
    var isAuthenticated: Bool { get }
    var isConnecting: Bool { get }
    var isConfigured: Bool { get }
    var config: ServerConfig { get }

    func authenticate() async throws
    func disconnect()
    func updateConfig(_ newConfig: ServerConfig)
    func getChannels() async throws -> [Channel]
    func getListings(channelId: Int) async throws -> [Program]
    func getAllListings(for channels: [Channel]) async throws -> [Int: [Program]]
    func getAllRecordings() async throws -> (completed: [Recording], recording: [Recording], scheduled: [Recording])
    func scheduleRecording(eventId: Int) async throws
    func scheduleRecording(program: Program, channel: Channel?) async throws
    func scheduleSeriesRecording(eventId: Int) async throws
    func cancelRecording(recordingId: Int) async throws
    func cancelSeriesRecording(recurringId: Int) async throws
    func getRecurringRecordings() async throws -> [RecurringRecording]
    func setRecordingPosition(recordingId: Int, positionSeconds: Int) async throws
    func liveStreamURL(channelId: Int) async throws -> URL
    func recordingStreamURL(recordingId: Int) async throws -> URL
    func streamAuthHeaders() -> [String: String]
    func channelIconURL(channelId: Int) throws -> URL?
    func recordingArtworkURL(recordingId: Int, fanart: Bool) -> URL?
}

extension PVRClientProtocol {
    func scheduleRecording(program: Program, channel: Channel?) async throws {
        _ = channel
        try await scheduleRecording(eventId: program.id)
    }
}
