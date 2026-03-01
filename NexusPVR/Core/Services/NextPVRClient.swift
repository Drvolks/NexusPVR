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
final class NextPVRClient: ObservableObject, PVRClientProtocol {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isConnecting = false
    @Published private(set) var lastError: NextPVRError?

    private(set) var config: ServerConfig
    private var sid: String?
    private let session: URLSession
    private let deviceName = Brand.deviceName
    private let liveClientName: String

    private static let liveClientIDKey = "NextPVRLiveClientID"

    init(config: ServerConfig? = nil) {
        self.config = config ?? ServerConfig.load()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
        self.liveClientName = Self.makeLiveClientName()
    }

    private static func makeLiveClientName() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: liveClientIDKey), !existing.isEmpty {
            return "\(Brand.deviceName)-\(existing)"
        }
        let id = String(UUID().uuidString.prefix(8))
        defaults.set(id, forKey: liveClientIDKey)
        return "\(Brand.deviceName)-\(id)"
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

    // MARK: - Network Logging

    private func sanitizePath(_ url: URL?) -> String {
        guard let url else { return "?" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let sensitiveKeys: Set<String> = ["md5", "sid"]
        if let items = components?.queryItems {
            components?.queryItems = items.map { item in
                if sensitiveKeys.contains(item.name.lowercased()) {
                    return URLQueryItem(name: item.name, value: "***")
                }
                return item
            }
        }
        let path = components?.path ?? url.path
        if let query = components?.query, !query.isEmpty {
            return "\(path)?\(query)"
        }
        return path
    }

    private static let retryDelays: [Double] = [1.0, 2.0, 3.0, 5.0]
    private static let maxAttempts = 5

    private func loggedData(from url: URL) async throws -> (Data, URLResponse) {
        let method = "GET"
        let path = sanitizePath(url)
        var lastError: Error?

        for attempt in 1...Self.maxAttempts {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode
                let ok = status.map { (200...399).contains($0) } ?? false
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(), method: method, path: path,
                    statusCode: status, isSuccess: ok,
                    durationMs: ms, responseSize: data.count,
                    errorDetail: ok ? nil : String(data: Data(data.prefix(1024)), encoding: .utf8)
                ))
                return (data, response)
            } catch {
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                lastError = error

                let isTransient = (error as? URLError)?.code == .notConnectedToInternet && ms < 200
                let willRetry = isTransient && attempt < Self.maxAttempts
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(), method: method, path: path,
                    statusCode: nil, isSuccess: false,
                    durationMs: ms, responseSize: 0,
                    errorDetail: error.localizedDescription + (willRetry ? " (retrying \(attempt)/\(Self.maxAttempts))" : "")
                ))

                if willRetry {
                    let delay = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }

                throw error
            }
        }

        throw lastError!
    }

    // MARK: - Authentication

    func authenticate() async throws {
        guard !config.isDemoMode else { isAuthenticated = true; return }

        guard config.isConfigured else {
            throw NextPVRError.notConfigured
        }

        isConnecting = true
        lastError = nil

        defer { isConnecting = false }

        do {
            // Step 1: Initiate session
            let initiateURL = URL(string: "\(baseURL)/services/service?method=session.initiate&ver=1.0&device=\(deviceName)&format=json")!
            let (initiateData, _) = try await loggedData(from: initiateURL)
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
            let (loginData, _) = try await loggedData(from: loginURL)
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
            let (data, response) = try await loggedData(from: url)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                // Session expired, re-authenticate
                isAuthenticated = false
                try await authenticate()
                return try await request(method, params: params)
            }

            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as NextPVRError {
            throw error
        } catch is DecodingError {
            throw NextPVRError.invalidResponse
        } catch {
            throw NextPVRError.networkError(error)
        }
    }

    // MARK: - Channels

    func getChannels() async throws -> [Channel] {
        guard !config.isDemoMode else { return DemoDataProvider.channels }
        let response: ChannelListResponse = try await request("channel.list")
        return response.channels ?? []
    }

    // MARK: - EPG / Listings

    func getListings(channelId: Int) async throws -> [Program] {
        guard !config.isDemoMode else { return DemoDataProvider.listings(for: channelId) }
        let response: ProgramListingsResponse = try await request("channel.listings", params: ["channel_id": String(channelId)])
        return response.listings ?? []
    }

    func getAllListings(for channels: [Channel]) async throws -> [Int: [Program]] {
        guard !config.isDemoMode else { return DemoDataProvider.allListings(for: channels) }
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
        guard !config.isDemoMode else { return [] }
        let response: RecordingListResponse = try await request("recording.list", params: ["filter": filter])
        return response.recordings ?? []
    }

    func getAllRecordings() async throws -> (completed: [Recording], recording: [Recording], scheduled: [Recording]) {
        guard !config.isDemoMode else { return DemoDataProvider.recordings() }
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
        guard !config.isDemoMode else { DemoDataProvider.scheduleRecording(eventId: eventId); return }
        let response: APIResponse = try await request("recording.save", params: ["event_id": String(eventId)])
        if !response.isSuccess {
            throw NextPVRError.apiError("Failed to schedule recording")
        }
    }

    func cancelRecording(recordingId: Int) async throws {
        guard !config.isDemoMode else { DemoDataProvider.cancelRecording(recordingId: recordingId); return }
        let response: APIResponse = try await request("recording.delete", params: ["recording_id": String(recordingId)])
        if !response.isSuccess {
            throw NextPVRError.apiError("Failed to cancel recording")
        }
    }

    func setRecordingPosition(recordingId: Int, positionSeconds: Int) async throws {
        guard !config.isDemoMode else { return }
        let _: APIResponse = try await request("recording.watched.set", params: [
            "recording_id": String(recordingId),
            "position": String(positionSeconds)
        ])
        // Non-fatal — ignore failures
    }

    // MARK: - Streaming URLs

    func liveStreamURL(channelId: Int) async throws -> URL {
        guard !config.isDemoMode else { return DemoDataProvider.demoVideoURL }
        if !isAuthenticated {
            try await authenticate()
        }
        guard let sid else { throw NextPVRError.sessionExpired }

        var components = URLComponents(string: "\(baseURL)/live")
        components?.queryItems = [
            URLQueryItem(name: "channeloid", value: String(channelId)),
            URLQueryItem(name: "client", value: liveClientName),
            URLQueryItem(name: "sid", value: sid)
        ]
        guard let url = components?.url else {
            throw NextPVRError.invalidResponse
        }
        return url
    }

    func recordingStreamURL(recordingId: Int) async throws -> URL {
        guard !config.isDemoMode else { return DemoDataProvider.demoVideoURL }
        if !isAuthenticated {
            try await authenticate()
        }
        guard let sid else { throw NextPVRError.sessionExpired }
        guard let url = URL(string: "\(baseURL)/live?recording=\(recordingId)&sid=\(sid)") else {
            throw NextPVRError.invalidResponse
        }
        return url
    }

    func streamAuthHeaders() -> [String: String] {
        [:]  // NextPVR uses SID in URL
    }

    func channelIconURL(channelId: Int) throws -> URL? {
        guard let sid else { throw NextPVRError.sessionExpired }
        guard !config.isDemoMode else { return DemoDataProvider.channelIconURL(channelId: channelId) }
        return URL(string: "\(baseURL)/service?method=channel.icon&channel_id=\(channelId)&sid=\(sid)")
    }
}
