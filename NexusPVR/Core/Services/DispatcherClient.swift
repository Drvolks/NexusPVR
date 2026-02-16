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
        guard !config.isDemoMode else { isAuthenticated = true; return }

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

            return try await Self.decodeOffMainActor(data)
        } catch let error as PVRClientError {
            throw error
        } catch is DecodingError {
            throw PVRClientError.invalidResponse
        } catch {
            throw PVRClientError.networkError(error)
        }
    }

    /// Decode JSON off the main actor to avoid blocking the UI
    private nonisolated static func decodeOffMainActor<T: Decodable>(_ data: Data) async throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
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
    /// - Parameter maxPages: Maximum number of pages to fetch (0 = unlimited). Prevents unbounded memory usage for large datasets.
    private func fetchAllPages<T: Decodable>(_ url: URL, maxPages: Int = 0) async throws -> [T] {
        var allItems = [T]()
        var nextURL: URL? = url
        var pageCount = 0

        while let currentURL = nextURL {
            let response: DispatcharrListResponse<T> = try await authenticatedRequest(currentURL)
            allItems.append(contentsOf: response.allItems)
            pageCount += 1

            if maxPages > 0 && pageCount >= maxPages {
                break
            }

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
        guard !config.isDemoMode else { return DemoDataProvider.channels }
        // Request large page to minimize pagination round-trips
        guard let url = URL(string: "\(baseURL)/api/channels/channels/?page_size=10000") else {
            throw PVRClientError.invalidResponse
        }

        let channelsStart = CFAbsoluteTimeGetCurrent()
        let items: [DispatcharrChannel] = try await fetchAllPages(url)
        print("[Dispatcharr] Fetched \(items.count) channels in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - channelsStart) * 1000))ms")

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

        // Resolve EPG data tvg_ids concurrently for channels where the channel's tvg_id
        // differs from the EPG source's tvg_id (e.g. "CBCNews.ca" vs "CBCNewsNetwork.ca")
        let epgResolveStart = CFAbsoluteTimeGetCurrent()
        let channelsNeedingResolve = items.filter { $0.epgDataId != nil }
        let concurrencyLimit = 20
        let resolvedMappings = await withTaskGroup(of: (Int, String?).self) { group in
            var results = [(Int, String?)]()
            var index = 0

            for ch in channelsNeedingResolve {
                guard let epgDataId = ch.epgDataId else { continue }
                guard let epgURL = URL(string: "\(baseURL)/api/epg/epgdata/\(epgDataId)/") else { continue }

                if index >= concurrencyLimit {
                    if let result = await group.next() {
                        results.append(result)
                    }
                }

                let channelId = ch.id
                group.addTask { [weak self] in
                    guard let self else { return (channelId, nil) }
                    do {
                        let epgData: DispatcharrEPGData = try await self.authenticatedRequest(epgURL)
                        return (channelId, epgData.tvgId)
                    } catch {
                        return (channelId, nil)
                    }
                }
                index += 1
            }

            for await result in group {
                results.append(result)
            }
            return results
        }
        for (channelId, epgTvgId) in resolvedMappings {
            if let epgTvgId, !epgTvgId.isEmpty,
               tvgIdToChannelId[epgTvgId] == nil {
                tvgIdToChannelId[epgTvgId] = channelId
            }
        }
        print("[Dispatcharr] Resolved \(channelsNeedingResolve.count) EPG data mappings in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - epgResolveStart) * 1000))ms")

        return items.map { $0.toChannel() }
    }

    // MARK: - EPG / Listings

    func getListings(channelId: Int) async throws -> [Program] {
        guard !config.isDemoMode else { return DemoDataProvider.listings(for: channelId) }
        guard let url = URL(string: "\(baseURL)/api/epg/grid/?page_size=50000") else {
            throw PVRClientError.invalidResponse
        }

        // Find the tvg_id for this channel (reverse lookup)
        let tvgId = tvgIdToChannelId.first(where: { $0.value == channelId })?.key

        let allPrograms: [DispatcharrProgram] = try await fetchAllPages(url, maxPages: 50)
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
            .compactMap { $0.toProgram(channelId: channelId) }
        return programs
    }

    func getAllListings(for channels: [Channel]) async throws -> [Int: [Program]] {
        guard !config.isDemoMode else { return DemoDataProvider.allListings(for: channels) }
        if !isAuthenticated {
            try await authenticate()
        }

        guard let url = URL(string: "\(baseURL)/api/epg/grid/?page_size=50000") else {
            throw PVRClientError.invalidResponse
        }

        let allPrograms: [DispatcharrProgram] = try await fetchAllPages(url, maxPages: 50)

        // Process programs off the main actor to avoid blocking the UI
        let tvgMap = tvgIdToChannelId
        let result = await Task.detached(priority: .userInitiated) {
            var mapped = [Int: [Program]]()
            for program in allPrograms {
                let channelId: Int?
                if let directId = program.channel {
                    channelId = directId
                } else if let tvgId = program.tvgId, !tvgId.isEmpty {
                    channelId = tvgMap[tvgId]
                } else {
                    channelId = nil
                }
                guard let resolvedId = channelId else { continue }
                guard let p = program.toProgram(channelId: resolvedId) else { continue }
                mapped[resolvedId, default: []].append(p)
            }
            return mapped
        }.value

        return result
    }

    // MARK: - Recordings

    func getAllRecordings() async throws -> (completed: [Recording], recording: [Recording], scheduled: [Recording]) {
        guard !config.isDemoMode else { return DemoDataProvider.recordings() }
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
        guard !config.isDemoMode else { DemoDataProvider.scheduleRecording(eventId: eventId); return }
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
        guard !config.isDemoMode else { DemoDataProvider.cancelRecording(recordingId: recordingId); return }
        guard let url = URL(string: "\(baseURL)/api/channels/recordings/\(recordingId)/") else {
            throw PVRClientError.invalidResponse
        }

        try await authenticatedRequestNoContent(url, method: "DELETE")
    }

    func setRecordingPosition(recordingId: Int, positionSeconds: Int) async throws {
        guard !config.isDemoMode else { return }
        // Dispatcharr doesn't natively support playback position tracking
        // Store locally in UserDefaults as a fallback
        UserDefaults.standard.set(positionSeconds, forKey: "recording_position_\(recordingId)")
    }

    // MARK: - Streaming URLs

    func liveStreamURL(channelId: Int) async throws -> URL {
        guard !config.isDemoMode else { return DemoDataProvider.demoVideoURL }
        guard let uuid = channelIdToUUID[channelId] else {
            throw PVRClientError.apiError("No stream UUID for channel \(channelId)")
        }

        // Proxy stream uses channel UUID, no auth needed (HDHR-compatible endpoint)
        guard let url = URL(string: "\(baseURL)/proxy/ts/stream/\(uuid)") else {
            throw PVRClientError.invalidResponse
        }

        return url
    }

    func recordingStreamURL(recordingId: Int) async throws -> URL {
        guard !config.isDemoMode else { return DemoDataProvider.demoVideoURL }
        if !isAuthenticated {
            try await authenticate()
        }

        guard let url = URL(string: "\(baseURL)/api/channels/recordings/\(recordingId)/file/") else {
            throw PVRClientError.invalidResponse
        }

        return url
    }

    func channelIconURL(channelId: Int) -> URL? {
        guard !config.isDemoMode else { return DemoDataProvider.channelIconURL(channelId: channelId) }
        guard let logoId = channelIdToLogoId[channelId],
              let token = accessToken else { return nil }
        return URL(string: "\(baseURL)/api/channels/logos/\(logoId)/cache/?token=\(token)")
    }

    // MARK: - Proxy Status

    func getProxyStatus() async throws -> ProxyStatusResponse {
        guard !config.isDemoMode else { return ProxyStatusResponse(count: 0, channels: []) }
        guard let url = URL(string: "\(baseURL)/proxy/ts/status") else {
            throw PVRClientError.invalidResponse
        }
        return try await authenticatedRequest(url)
    }

    // MARK: - M3U Accounts

    func getM3UAccounts() async throws -> [M3UAccount] {
        guard !config.isDemoMode else { return [] }
        guard let url = URL(string: "\(baseURL)/api/m3u/accounts/") else {
            throw PVRClientError.invalidResponse
        }
        let items: [M3UAccount] = try await fetchAllPages(url)
        return items
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // id can be Int or String
        if let intId = try? container.decode(Int.self, forKey: .id) {
            id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id),
                  let parsed = Int(stringId) {
            id = parsed
        } else {
            let raw = try container.decode(String.self, forKey: .id)
            id = abs(raw.hashValue)
        }

        name = try container.decode(String.self, forKey: .name)
        channelNumber = try container.decodeIfPresent(Double.self, forKey: .channelNumber)
        tvgId = try container.decodeIfPresent(String.self, forKey: .tvgId)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)

        // logo_id can be Int or String
        if let intLogo = try? container.decode(Int.self, forKey: .logoId) {
            logoId = intLogo
        } else if let stringLogo = try? container.decodeIfPresent(String.self, forKey: .logoId),
                  let parsed = Int(stringLogo) {
            logoId = parsed
        } else {
            logoId = nil
        }

        // epg_data_id can be Int or String
        if let intEpg = try? container.decode(Int.self, forKey: .epgDataId) {
            epgDataId = intEpg
        } else if let stringEpg = try? container.decodeIfPresent(String.self, forKey: .epgDataId),
                  let parsed = Int(stringEpg) {
            epgDataId = parsed
        } else {
            epgDataId = nil
        }
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // id can be Int or String from Dispatcharr
        if let intId = try? container.decode(Int.self, forKey: .id) {
            id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id),
                  let parsed = Int(stringId) {
            id = parsed
        } else {
            // Use hash of the string value as fallback
            let raw = try container.decode(String.self, forKey: .id)
            id = abs(raw.hashValue)
        }

        startTime = try container.decode(String.self, forKey: .startTime)
        endTime = try container.decode(String.self, forKey: .endTime)
        title = try container.decode(String.self, forKey: .title)
        subTitle = try container.decodeIfPresent(String.self, forKey: .subTitle)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        tvgId = try container.decodeIfPresent(String.self, forKey: .tvgId)

        // channel can also be Int or String
        if let intCh = try? container.decode(Int.self, forKey: .channel) {
            channel = intCh
        } else if let stringCh = try? container.decodeIfPresent(String.self, forKey: .channel),
                  let parsed = Int(stringCh) {
            channel = parsed
        } else {
            channel = nil
        }
    }

    func toProgram(channelId: Int? = nil) -> Program? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        guard let startDate = formatter.date(from: startTime) ?? fallbackFormatter.date(from: startTime),
              let endDate = formatter.date(from: endTime) ?? fallbackFormatter.date(from: endTime),
              endDate > startDate else {
            return nil
        }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let intId = try? container.decode(Int.self, forKey: .id) {
            id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id),
                  let parsed = Int(stringId) {
            id = parsed
        } else {
            let raw = try container.decode(String.self, forKey: .id)
            id = abs(raw.hashValue)
        }

        startTime = try container.decode(String.self, forKey: .startTime)
        endTime = try container.decode(String.self, forKey: .endTime)
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        customProperties = try container.decodeIfPresent(DispatcharrCustomProperties.self, forKey: .customProperties)

        if let intCh = try? container.decode(Int.self, forKey: .channel) {
            channel = intCh
        } else if let stringCh = try? container.decode(String.self, forKey: .channel),
                  let parsed = Int(stringCh) {
            channel = parsed
        } else {
            channel = 0
        }
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

// MARK: - M3U Account Model

struct M3UAccount: Decodable, Identifiable {
    let id: Int
    let name: String
    let serverUrl: String
    let status: String
    let updatedAt: String?
    let isActive: Bool
    let locked: Bool
    let accountType: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, locked
        case serverUrl = "server_url"
        case updatedAt = "updated_at"
        case isActive = "is_active"
        case accountType = "account_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // id can be Int or String
        if let intId = try? container.decode(Int.self, forKey: .id) {
            id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id),
                  let parsed = Int(stringId) {
            id = parsed
        } else {
            let raw = try container.decode(String.self, forKey: .id)
            id = abs(raw.hashValue)
        }

        name = (try? container.decode(String.self, forKey: .name)) ?? "Unknown"
        serverUrl = (try? container.decode(String.self, forKey: .serverUrl)) ?? ""
        status = (try? container.decode(String.self, forKey: .status)) ?? "unknown"
        updatedAt = try? container.decode(String.self, forKey: .updatedAt)
        accountType = try? container.decode(String.self, forKey: .accountType)

        // is_active can be Bool or Int (0/1)
        if let boolVal = try? container.decode(Bool.self, forKey: .isActive) {
            isActive = boolVal
        } else if let intVal = try? container.decode(Int.self, forKey: .isActive) {
            isActive = intVal != 0
        } else {
            isActive = true
        }

        // locked can be Bool or Int (0/1)
        if let boolVal = try? container.decode(Bool.self, forKey: .locked) {
            locked = boolVal
        } else if let intVal = try? container.decode(Int.self, forKey: .locked) {
            locked = intVal != 0
        } else {
            locked = false
        }
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
