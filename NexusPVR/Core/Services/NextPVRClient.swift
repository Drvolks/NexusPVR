//
//  NextPVRClient.swift
//  nextpvr-apple-client
//
//  NextPVR API client with MD5 authentication
//

import Foundation
import Combine

enum NextPVRError: Error, LocalizedError {
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
            return "Authentication failed. Check your PIN."
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
final class NextPVRClient: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isConnecting = false
    @Published private(set) var lastError: NextPVRError?

    private(set) var config: ServerConfig
    private var sid: String?
    private let session: URLSession
    private let deviceName = "NextPVR-Apple"

    init(config: ServerConfig? = nil) {
        self.config = config ?? ServerConfig.load()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    var baseURL: String {
        config.baseURL
    }

    var isConfigured: Bool {
        config.isConfigured
    }

    func updateConfig(_ newConfig: ServerConfig) {
        config = newConfig
        sid = nil
        isAuthenticated = false
    }

    // MARK: - Authentication

    func authenticate() async throws {
        guard config.isConfigured else {
            throw NextPVRError.notConfigured
        }

        isConnecting = true
        lastError = nil

        defer { isConnecting = false }

        do {
            // Step 1: Initiate session
            let initiateURL = URL(string: "\(baseURL)/services/service?method=session.initiate&ver=1.0&device=\(deviceName)&format=json")!
            let (initiateData, _) = try await session.data(from: initiateURL)
            let initiateResponse = try JSONDecoder().decode(SessionInitiateResponse.self, from: initiateData)

            guard let tempSid = initiateResponse.sid, let salt = initiateResponse.salt else {
                throw NextPVRError.invalidResponse
            }

            // Step 2: Compute hash: md5(":" + md5(PIN) + ":" + salt)
            let pinMd5 = MD5Hasher.hash(config.pin)
            let combined = ":\(pinMd5):\(salt)"
            let loginHash = MD5Hasher.hash(combined)

            // Step 3: Login
            let loginURL = URL(string: "\(baseURL)/services/service?method=session.login&sid=\(tempSid)&md5=\(loginHash)&format=json")!
            let (loginData, _) = try await session.data(from: loginURL)
            let loginResponse = try JSONDecoder().decode(SessionLoginResponse.self, from: loginData)

            if loginResponse.isSuccess {
                sid = tempSid
                isAuthenticated = true
            } else {
                throw NextPVRError.authenticationFailed
            }
        } catch let error as NextPVRError {
            lastError = error
            throw error
        } catch {
            let npvrError = NextPVRError.networkError(error)
            lastError = npvrError
            throw npvrError
        }
    }

    func disconnect() {
        sid = nil
        isAuthenticated = false
    }

    // MARK: - API Requests

    private func request<T: Decodable>(_ method: String, params: [String: String] = [:]) async throws -> T {
        if !isAuthenticated {
            try await authenticate()
        }

        guard let sid else {
            throw NextPVRError.sessionExpired
        }

        var components = URLComponents(string: "\(baseURL)/services/service")!
        var queryItems = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "sid", value: sid),
            URLQueryItem(name: "format", value: "json")
        ]

        for (key, value) in params {
            queryItems.append(URLQueryItem(name: key, value: value))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw NextPVRError.invalidResponse
        }

        do {
            let (data, response) = try await session.data(from: url)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                // Session expired, re-authenticate
                isAuthenticated = false
                try await authenticate()
                return try await request(method, params: params)
            }

            #if DEBUG
            if let jsonString = String(data: data, encoding: .utf8) {
                print("NextPVR API Response for \(method):")
                print(jsonString.prefix(1000))
            }
            #endif

            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as NextPVRError {
            throw error
        } catch let error as DecodingError {
            #if DEBUG
            print("NextPVR Decoding Error: \(error)")
            #endif
            throw NextPVRError.invalidResponse
        } catch {
            throw NextPVRError.networkError(error)
        }
    }

    // MARK: - Channels

    func getChannels() async throws -> [Channel] {
        let response: ChannelListResponse = try await request("channel.list")
        return response.channels ?? []
    }

    // MARK: - EPG / Listings

    func getListings(channelId: Int) async throws -> [Program] {
        let response: ProgramListingsResponse = try await request("channel.listings", params: ["channel_id": String(channelId)])
        return response.listings ?? []
    }

    func getAllListings(for channels: [Channel]) async throws -> [Int: [Program]] {
        var result = [Int: [Program]]()

        // Ensure we're authenticated before starting batch requests
        if !isAuthenticated {
            try await authenticate()
        }

        // Fetch in batches to avoid overwhelming the server
        // Use sequential requests within batches to avoid race conditions with session state
        let batchSize = 10
        for batchStart in stride(from: 0, to: channels.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, channels.count)
            let batch = Array(channels[batchStart..<batchEnd])

            for channel in batch {
                do {
                    let listings = try await getListings(channelId: channel.id)
                    result[channel.id] = listings
                } catch {
                    result[channel.id] = []
                }
            }
        }

        return result
    }

    // MARK: - Recordings

    func getRecordings(filter: String = "ready") async throws -> [Recording] {
        let response: RecordingListResponse = try await request("recording.list", params: ["filter": filter])
        #if DEBUG
        print("NextPVR: Fetched \(response.recordings?.count ?? 0) recordings with filter '\(filter)'")
        #endif
        return response.recordings ?? []
    }

    func getAllRecordings() async throws -> (completed: [Recording], recording: [Recording], scheduled: [Recording]) {
        async let ready = getRecordings(filter: "ready")
        async let inProgress = getRecordings(filter: "recording")
        async let pending = getRecordings(filter: "pending")

        let (readyResults, inProgressResults, pendingResults) = try await (ready, inProgress, pending)

        // Merge all results, deduplicating by ID
        // Prefer the version from "recording" filter, then "ready", then "pending"
        var recordingsById: [Int: Recording] = [:]
        for recording in pendingResults { recordingsById[recording.id] = recording }
        for recording in readyResults { recordingsById[recording.id] = recording }
        for recording in inProgressResults { recordingsById[recording.id] = recording }

        // Categorize by actual status rather than which filter returned them
        var completed: [Recording] = []
        var active: [Recording] = []
        var scheduled: [Recording] = []

        for recording in recordingsById.values {
            switch recording.recordingStatus {
            case .recording:
                active.append(recording)
            case .ready:
                completed.append(recording)
            case .pending, .conflict:
                scheduled.append(recording)
            default:
                completed.append(recording)
            }
        }

        return (completed, active, scheduled)
    }

    func scheduleRecording(eventId: Int) async throws {
        let response: APIResponse = try await request("recording.save", params: ["event_id": String(eventId)])
        if !response.isSuccess {
            throw NextPVRError.apiError("Failed to schedule recording")
        }
    }

    func cancelRecording(recordingId: Int) async throws {
        let response: APIResponse = try await request("recording.delete", params: ["recording_id": String(recordingId)])
        if !response.isSuccess {
            throw NextPVRError.apiError("Failed to cancel recording")
        }
    }

    func setRecordingPosition(recordingId: Int, positionSeconds: Int) async throws {
        let response: APIResponse = try await request("recording.watched.set", params: [
            "recording_id": String(recordingId),
            "position": String(positionSeconds)
        ])
        if !response.isSuccess {
            #if DEBUG
            print("NextPVR: Failed to set recording position (non-fatal)")
            #endif
        }
    }

    // MARK: - Streaming URLs

    func liveStreamURL(channelId: Int) async throws -> URL {
        if !isAuthenticated {
            try await authenticate()
        }
        guard let sid else { throw NextPVRError.sessionExpired }

        // NextPVR v7 uses /stream endpoint with m3u8 for HLS
        // Try different URL formats
        let urlFormats = [
            "\(baseURL)/stream?channel=\(channelId)&sid=\(sid)",
            "\(baseURL)/services/service?method=channel.stream&channel_id=\(channelId)&sid=\(sid)&format=m3u8",
            "\(baseURL)/live?channel=\(channelId)&sid=\(sid)&format=m3u8",
            "\(baseURL)/live?channel=\(channelId)&client=\(deviceName)",
        ]

        // For now, use the first format - we can test others
        guard let url = URL(string: urlFormats[0]) else {
            throw NextPVRError.invalidResponse
        }

        #if DEBUG
        print("Live stream URL: \(url.absoluteString)")
        print("Alternative URLs to try:")
        for (i, fmt) in urlFormats.enumerated() {
            print("  [\(i)]: \(fmt)")
        }
        #endif

        return url
    }

    func recordingStreamURL(recordingId: Int) async throws -> URL {
        if !isAuthenticated {
            try await authenticate()
        }
        guard let sid else { throw NextPVRError.sessionExpired }
        guard let url = URL(string: "\(baseURL)/live?recording=\(recordingId)&sid=\(sid)") else {
            throw NextPVRError.invalidResponse
        }
        return url
    }

    func channelIconURL(channelId: Int) -> URL? {
        URL(string: "\(baseURL)/service?method=channel.icon&channel_id=\(channelId)")
    }
}
