//
//  PVRClientProtocol.swift
//  PVR Client
//
//  Shared protocol for PVR API clients
//

import Foundation

enum PVRClientError: Error, LocalizedError {
    case notConfigured
    case authenticationFailed
    case sessionExpired
    case networkError(Error)
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Server not configured"
        case .authenticationFailed:
            return "Authentication failed. Check your credentials."
        case .sessionExpired:
            return "Session expired. Please reconnect."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .apiError(let message):
            return message
        }
    }
}

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
    func cancelRecording(recordingId: Int) async throws
    func setRecordingPosition(recordingId: Int, positionSeconds: Int) async throws
    func liveStreamURL(channelId: Int) async throws -> URL
    func recordingStreamURL(recordingId: Int) async throws -> URL
    func channelIconURL(channelId: Int) throws -> URL?
}
