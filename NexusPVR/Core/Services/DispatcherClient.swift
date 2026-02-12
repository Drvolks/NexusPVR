//
//  DispatcherClient.swift
//  DispatcherPVR
//
//  Dispatcharr REST API client with JWT authentication
//

import Foundation
import Combine

@MainActor
final class DispatcherClient: ObservableObject, PVRClientProtocol {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isConnecting = false

    private(set) var config: ServerConfig
    private var accessToken: String?
    private var refreshToken: String?
    private let session: URLSession
    /// Maps tvg_id (e.g. "TSN1.ca") → channel id for EPG lookups
    private var tvgIdToChannelId: [String: Int] = [:]
    /// Maps channel id → logo id for icon URLs
    private var channelIdToLogoId: [Int: Int] = [:]
    /// Maps channel id → UUID for stream URLs
    private var channelIdToUUID: [Int: String] = [:]

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
        accessToken = nil
        refreshToken = nil
        isAuthenticated = false
    }

    // MARK: - Authentication

    func authenticate() async throws {
        guard config.isConfigured else {
            throw PVRClientError.notConfigured
        }

        isConnecting = true
        defer { isConnecting = false }

        guard let url = URL(string: "\(baseURL)/api/accounts/token/") else {
            throw PVRClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "username": config.username,
            "password": config.password
        ]
        request.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PVRClientError.invalidResponse
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 400 {
                throw PVRClientError.authenticationFailed
            }

            guard httpResponse.statusCode == 200 else {
                throw PVRClientError.invalidResponse
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            accessToken = tokenResponse.access
            refreshToken = tokenResponse.refresh
            isAuthenticated = true
        } catch let error as PVRClientError {
            throw error
        } catch {
            throw PVRClientError.networkError(error)
        }
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        isAuthenticated = false
    }

    // MARK: - Token Refresh

    private func refreshAccessToken() async throws {
        guard let refreshToken else {
            throw PVRClientError.sessionExpired
        }

        guard let url = URL(string: "\(baseURL)/api/accounts/token/refresh/") else {
            throw PVRClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["refresh": refreshToken]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            // Refresh failed, need full re-auth
            self.refreshToken = nil
            throw PVRClientError.sessionExpired
        }

        let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        accessToken = tokenResponse.access
    }

    // MARK: - Authenticated Requests

    private func authenticatedRequest<T: Decodable>(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> T {
        if !isAuthenticated {
            try await authenticate()
        }

        guard let accessToken else {
            throw PVRClientError.sessionExpired
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        do {
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                // Try refreshing the token
                do {
                    try await refreshAccessToken()
                    return try await authenticatedRequest(url, method: method, body: body)
                } catch {
                    // Refresh failed, full re-auth
                    isAuthenticated = false
                    try await authenticate()
                    return try await authenticatedRequest(url, method: method, body: body)
                }
            }

            #if DEBUG
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Dispatcharr API Response for \(url.path):")
                print(jsonString.prefix(1000))
            }
            #endif

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch let error as PVRClientError {
            throw error
        } catch let error as DecodingError {
            #if DEBUG
            print("Dispatcharr Decoding Error: \(error)")
            #endif
            throw PVRClientError.invalidResponse
        } catch {
            throw PVRClientError.networkError(error)
        }
    }

    private func authenticatedRequestNoContent(_ url: URL, method: String = "DELETE") async throws {
        if !isAuthenticated {
            try await authenticate()
        }

        guard let accessToken else {
            throw PVRClientError.sessionExpired
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                do {
                    try await refreshAccessToken()
                    try await authenticatedRequestNoContent(url, method: method)
                    return
                } catch {
                    isAuthenticated = false
                    try await authenticate()
                    try await authenticatedRequestNoContent(url, method: method)
                    return
                }
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw PVRClientError.apiError("Request failed with status \(httpResponse.statusCode)")
            }
        }
    }

    /// Fetch all items from a paginated Dispatcharr endpoint
    private func fetchAllPages<T: Decodable>(_ url: URL) async throws -> [T] {
        var allItems = [T]()
        var nextURL: URL? = url

        while let currentURL = nextURL {
            let response: DispatcharrListResponse<T> = try await authenticatedRequest(currentURL)
            allItems.append(contentsOf: response.allItems)

            if let next = response.next, let url = URL(string: next) {
                nextURL = url
            } else {
                nextURL = nil
            }
        }

        return allItems
    }

    // MARK: - Channels

    func getChannels() async throws -> [Channel] {
        guard let url = URL(string: "\(baseURL)/api/channels/channels/") else {
            throw PVRClientError.invalidResponse
        }

        let items: [DispatcharrChannel] = try await fetchAllPages(url)

        // Build lookup maps for EPG, logo, and stream URL resolution
        tvgIdToChannelId = [:]
        channelIdToLogoId = [:]
        channelIdToUUID = [:]
        for ch in items {
            if let tvgId = ch.tvgId, !tvgId.isEmpty {
                tvgIdToChannelId[tvgId] = ch.id
            }
            if let logoId = ch.logoId {
                channelIdToLogoId[ch.id] = logoId
            }
            if let uuid = ch.uuid, !uuid.isEmpty {
                channelIdToUUID[ch.id] = uuid
            }
        }

        // Resolve EPG data tvg_ids for channels where the channel's tvg_id
        // differs from the EPG source's tvg_id (e.g. "CBCNews.ca" vs "CBCNewsNetwork.ca")
        for ch in items {
            guard let epgDataId = ch.epgDataId else { continue }
            guard let epgURL = URL(string: "\(baseURL)/api/epg/epgdata/\(epgDataId)/") else { continue }
            do {
                let epgData: DispatcharrEPGData = try await authenticatedRequest(epgURL)
                if let epgTvgId = epgData.tvgId, !epgTvgId.isEmpty,
                   tvgIdToChannelId[epgTvgId] == nil {
                    tvgIdToChannelId[epgTvgId] = ch.id
                }
            } catch {
                // Non-critical — skip if EPG data lookup fails
            }
        }

        return items.map { $0.toChannel() }
    }

    // MARK: - EPG / Listings

    func getListings(channelId: Int) async throws -> [Program] {
        guard let url = URL(string: "\(baseURL)/api/epg/grid/") else {
            throw PVRClientError.invalidResponse
        }

        // Find the tvg_id for this channel (reverse lookup)
        let tvgId = tvgIdToChannelId.first(where: { $0.value == channelId })?.key

        let allPrograms: [DispatcharrProgram] = try await fetchAllPages(url)
        let programs = allPrograms
            .filter { program in
                if let directId = program.channel, directId == channelId {
                    return true
                }
                if let tvgId, let programTvgId = program.tvgId, programTvgId == tvgId {
                    return true
                }
                return false
            }
            .map { $0.toProgram(channelId: channelId) }
        return programs
    }

    func getAllListings(for channels: [Channel]) async throws -> [Int: [Program]] {
        if !isAuthenticated {
            try await authenticate()
        }

        guard let url = URL(string: "\(baseURL)/api/epg/grid/") else {
            throw PVRClientError.invalidResponse
        }

        let allPrograms: [DispatcharrProgram] = try await fetchAllPages(url)
        var result = [Int: [Program]]()

        for program in allPrograms {
            // Resolve channel ID: try the direct channel field first,
            // then fall back to tvg_id → channel id mapping
            let channelId: Int?
            if let directId = program.channel {
                channelId = directId
            } else if let tvgId = program.tvgId, !tvgId.isEmpty {
                channelId = tvgIdToChannelId[tvgId]
            } else {
                channelId = nil
            }

            guard let resolvedId = channelId else { continue }
            let p = program.toProgram(channelId: resolvedId)
            result[resolvedId, default: []].append(p)
        }

        return result
    }

    // MARK: - Recordings

    func getAllRecordings() async throws -> (completed: [Recording], recording: [Recording], scheduled: [Recording]) {
        guard let url = URL(string: "\(baseURL)/api/channels/recordings/") else {
            throw PVRClientError.invalidResponse
        }

        let items: [DispatcharrRecording] = try await fetchAllPages(url)
        let recordings = items.map { $0.toRecording() }

        var completed: [Recording] = []
        var active: [Recording] = []
        var scheduled: [Recording] = []

        let now = Date()
        for recording in recordings {
            if let endDate = recording.endDate, endDate < now {
                completed.append(recording)
            } else if let startDate = recording.startDate, startDate <= now,
                      let endDate = recording.endDate, endDate > now {
                active.append(recording)
            } else {
                scheduled.append(recording)
            }
        }

        return (completed, active, scheduled)
    }

    func scheduleRecording(eventId: Int) async throws {
        // In Dispatcharr, scheduling requires start_time, end_time, and channel
        // The eventId here is a program ID — we need to look up the program details
        guard let programURL = URL(string: "\(baseURL)/api/epg/programs/\(eventId)/") else {
            throw PVRClientError.invalidResponse
        }

        let program: DispatcharrProgram = try await authenticatedRequest(programURL)

        // Resolve channel ID: try direct field, then tvg_id → channel mapping
        let channelId: Int
        if let directId = program.channel {
            channelId = directId
        } else if let tvgId = program.tvgId, let mappedId = tvgIdToChannelId[tvgId] {
            channelId = mappedId
        } else {
            throw PVRClientError.apiError("Cannot determine channel for this program")
        }

        guard let url = URL(string: "\(baseURL)/api/channels/recordings/") else {
            throw PVRClientError.invalidResponse
        }

        let recordingRequest = DispatcharrRecordingRequest(
            startTime: program.startTime,
            endTime: program.endTime,
            channel: channelId,
            customProperties: DispatcharrCustomProperties(
                program: DispatcharrProgramRef(
                    id: program.id,
                    startTime: program.startTime,
                    endTime: program.endTime,
                    title: program.title,
                    subTitle: program.subTitle,
                    description: program.description,
                    tvgId: program.tvgId
                )
            )
        )

        let encoder = JSONEncoder()
        let body = try encoder.encode(recordingRequest)

        let _: DispatcharrRecording = try await authenticatedRequest(url, method: "POST", body: body)
    }

    func cancelRecording(recordingId: Int) async throws {
        guard let url = URL(string: "\(baseURL)/api/channels/recordings/\(recordingId)/") else {
            throw PVRClientError.invalidResponse
        }

        try await authenticatedRequestNoContent(url, method: "DELETE")
    }

    func setRecordingPosition(recordingId: Int, positionSeconds: Int) async throws {
        // Dispatcharr doesn't natively support playback position tracking
        // Store locally in UserDefaults as a fallback
        UserDefaults.standard.set(positionSeconds, forKey: "recording_position_\(recordingId)")
    }

    // MARK: - Streaming URLs

    func liveStreamURL(channelId: Int) async throws -> URL {
        guard let uuid = channelIdToUUID[channelId] else {
            throw PVRClientError.apiError("No stream UUID for channel \(channelId)")
        }

        // Proxy stream uses channel UUID, no auth needed (HDHR-compatible endpoint)
        guard let url = URL(string: "\(baseURL)/proxy/ts/stream/\(uuid)") else {
            throw PVRClientError.invalidResponse
        }

        #if DEBUG
        print("Live stream URL: \(url.absoluteString)")
        #endif

        return url
    }

    func recordingStreamURL(recordingId: Int) async throws -> URL {
        if !isAuthenticated {
            try await authenticate()
        }

        guard let url = URL(string: "\(baseURL)/api/channels/recordings/\(recordingId)/file/") else {
            throw PVRClientError.invalidResponse
        }

        return url
    }

    func channelIconURL(channelId: Int) -> URL? {
        guard let logoId = channelIdToLogoId[channelId],
              let token = accessToken else { return nil }
        return URL(string: "\(baseURL)/api/channels/logos/\(logoId)/cache/?token=\(token)")
    }

    // MARK: - Proxy Status

    func getProxyStatus() async throws -> ProxyStatusResponse {
        guard let url = URL(string: "\(baseURL)/proxy/ts/status") else {
            throw PVRClientError.invalidResponse
        }
        return try await authenticatedRequest(url)
    }

}

// MARK: - API Response Models

private struct TokenResponse: Decodable {
    let access: String
    let refresh: String
}

private struct TokenRefreshResponse: Decodable {
    let access: String
}

/// Flexible list response that handles array, { results: [] }, or { data: [] }
struct DispatcharrListResponse<T: Decodable>: Decodable {
    let results: [T]?
    let data: [T]?
    let count: Int?
    let next: String?

    // Handle case where response is a plain array
    private let directItems: [T]?

    var allItems: [T] {
        results ?? data ?? directItems ?? []
    }

    init(from decoder: Decoder) throws {
        // Try decoding as an object with results/data
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            results = try container.decodeIfPresent([T].self, forKey: .results)
            data = try container.decodeIfPresent([T].self, forKey: .data)
            count = try container.decodeIfPresent(Int.self, forKey: .count)
            next = try container.decodeIfPresent(String.self, forKey: .next)
            directItems = nil
        } else {
            // Try decoding as a plain array
            let singleValueContainer = try decoder.singleValueContainer()
            directItems = try singleValueContainer.decode([T].self)
            results = nil
            data = nil
            count = nil
            next = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case results, data, count, next
    }
}

// MARK: - Dispatcharr API Models

struct DispatcharrChannel: Decodable {
    let id: Int
    let name: String
    let channelNumber: Double?
    let tvgId: String?
    let logoId: Int?
    let uuid: String?
    let epgDataId: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case channelNumber = "channel_number"
        case tvgId = "tvg_id"
        case logoId = "logo_id"
        case uuid
        case epgDataId = "epg_data_id"
    }

    func toChannel() -> Channel {
        Channel(
            id: id,
            name: name,
            number: Int(channelNumber ?? 0),
            hasIcon: logoId != nil
        )
    }
}

private struct DispatcharrEPGData: Decodable {
    let id: Int
    let tvgId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case tvgId = "tvg_id"
    }
}

struct DispatcharrProgram: Decodable {
    let id: Int
    let startTime: String
    let endTime: String
    let title: String
    let subTitle: String?
    let description: String?
    let tvgId: String?
    let channel: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case title
        case subTitle = "sub_title"
        case description
        case tvgId = "tvg_id"
        case channel
    }

    func toProgram(channelId: Int? = nil) -> Program {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let startDate = formatter.date(from: startTime) ?? ISO8601DateFormatter().date(from: startTime) ?? Date()
        let endDate = formatter.date(from: endTime) ?? ISO8601DateFormatter().date(from: endTime) ?? Date()

        return Program(
            id: id,
            name: title,
            subtitle: subTitle,
            desc: description,
            start: Int(startDate.timeIntervalSince1970),
            end: Int(endDate.timeIntervalSince1970),
            genres: nil,
            channelId: channelId ?? channel
        )
    }
}

struct DispatcharrRecording: Decodable {
    let id: Int
    let startTime: String
    let endTime: String
    let channel: Int
    let taskId: String?
    let customProperties: DispatcharrCustomProperties?

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case channel
        case taskId = "task_id"
        case customProperties = "custom_properties"
    }

    func toRecording() -> Recording {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let startDate = formatter.date(from: startTime) ?? ISO8601DateFormatter().date(from: startTime) ?? Date()
        let endDate = formatter.date(from: endTime) ?? ISO8601DateFormatter().date(from: endTime) ?? Date()

        let duration = Int(endDate.timeIntervalSince(startDate))
        let name = customProperties?.program?.title ?? "Recording"
        let subtitle = customProperties?.program?.subTitle
        let desc = customProperties?.program?.description
        let epgEventId = customProperties?.program?.id

        let now = Date()
        let status: String
        if endDate < now {
            status = "ready"
        } else if startDate <= now && endDate > now {
            status = "recording"
        } else {
            status = "pending"
        }

        // Check for locally stored playback position
        let playbackPosition = UserDefaults.standard.integer(forKey: "recording_position_\(id)")

        return Recording(
            id: id,
            name: name,
            subtitle: subtitle,
            desc: desc,
            startTime: Int(startDate.timeIntervalSince1970),
            duration: duration,
            channel: nil,
            channelId: channel,
            status: status,
            file: nil,
            recurring: false,
            recurringParent: nil,
            epgEventId: epgEventId,
            size: nil,
            quality: nil,
            genres: nil,
            playbackPosition: playbackPosition > 0 ? playbackPosition : nil
        )
    }
}

struct DispatcharrCustomProperties: Codable {
    let program: DispatcharrProgramRef?
}

struct DispatcharrProgramRef: Codable {
    let id: Int?
    let startTime: String?
    let endTime: String?
    let title: String?
    let subTitle: String?
    let description: String?
    let tvgId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case title
        case subTitle = "sub_title"
        case description
        case tvgId = "tvg_id"
    }
}

// MARK: - Proxy Status Models

struct ProxyStatusResponse: Decodable {
    let count: Int?
    let channels: [ProxyChannelStatus]?
}

struct ProxyChannelStatus: Decodable, Identifiable {
    var id: String { streamName }

    let streamName: String
    let state: String
    let resolution: String?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: String?
    let avgBitrate: String?
    let sourceFps: Double?
    let ffmpegSpeed: Double?
    let uptime: Double?
    let totalBytes: Int64?
    let m3uProfileName: String?
    let clientCount: Int?
    let clients: [ProxyClientInfo]?

    enum CodingKeys: String, CodingKey {
        case streamName = "stream_name"
        case state, resolution
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case audioChannels = "audio_channels"
        case avgBitrate = "avg_bitrate"
        case sourceFps = "source_fps"
        case ffmpegSpeed = "ffmpeg_speed"
        case uptime
        case totalBytes = "total_bytes"
        case m3uProfileName = "m3u_profile_name"
        case clientCount = "client_count"
        case clients
    }
}

struct ProxyClientInfo: Decodable, Identifiable {
    var id: String { ipAddress + userAgent }

    let ipAddress: String
    let userAgent: String
    let connectedSince: Double?

    enum CodingKeys: String, CodingKey {
        case ipAddress = "ip_address"
        case userAgent = "user_agent"
        case connectedSince = "connected_since"
    }
}

// MARK: - Recording Request Model

private struct DispatcharrRecordingRequest: Encodable {
    let startTime: String
    let endTime: String
    let channel: Int
    let customProperties: DispatcharrCustomProperties

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case channel
        case customProperties = "custom_properties"
    }
}
