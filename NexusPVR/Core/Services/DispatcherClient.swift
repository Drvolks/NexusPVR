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
    /// When true, use `X-API-Key` header instead of `Bearer` JWT
    private var useApiKeyAuth = false
    /// When true, use output/XC endpoints instead of REST API (for Streamer users)
    var useOutputEndpoints = false
    private let session: URLSession
    /// Maps tvg_id (e.g. "TSN1.ca") → channel id for EPG lookups
    private var tvgIdToChannelId: [String: Int] = [:]
    /// Maps channel id → logo id for icon URLs
    private var channelIdToLogoId: [Int: Int] = [:]
    /// Maps channel id → UUID for stream URLs
    private var channelIdToUUID: [Int: String] = [:]
    /// Direct logo URLs from M3U/XC parsing, keyed by channel ID
    private var channelLogoURLs: [Int: String] = [:]
    /// Channel groups extracted from M3U group-title or XC categories
    private var outputChannelGroups: [ChannelGroup] = []

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
        useApiKeyAuth = false
        useOutputEndpoints = false
        isAuthenticated = false
    }

    // MARK: - Authentication

    func authenticate() async throws {
        guard !config.isDemoMode else { isAuthenticated = true; return }

        guard config.isConfigured else {
            throw PVRClientError.notConfigured
        }

        // API key auth: use X-API-Key header, no JWT flow needed
        if !config.apiKey.isEmpty {
            isConnecting = true
            defer { isConnecting = false }

            // Probe /api/accounts/users/me/ — accessible to all authenticated users regardless of role
            guard let url = URL(string: "\(baseURL)/api/accounts/users/me/") else {
                throw PVRClientError.invalidResponse
            }

            var request = URLRequest(url: url)
            request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (_, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw PVRClientError.invalidResponse
                }
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw PVRClientError.authenticationFailed
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw PVRClientError.invalidResponse
                }
                accessToken = config.apiKey
                refreshToken = nil
                useApiKeyAuth = true
                isAuthenticated = true
            } catch let error as PVRClientError {
                throw error
            } catch {
                throw PVRClientError.networkError(error)
            }
            return
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
                // JWT failed — try XC API as fallback (password may be XC, not Django)
                if try await authenticateViaXC() { return }
                throw PVRClientError.authenticationFailed
            }

            guard httpResponse.statusCode == 200 else {
                throw PVRClientError.invalidResponse
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            accessToken = tokenResponse.access
            refreshToken = tokenResponse.refresh
            useApiKeyAuth = false
            isAuthenticated = true
        } catch let error as PVRClientError {
            throw error
        } catch {
            throw PVRClientError.networkError(error)
        }
    }

    /// Try authenticating via XC API (for streamer users with XC credentials)
    private func authenticateViaXC() async throws -> Bool {
        guard !config.username.isEmpty, !config.password.isEmpty else { return false }
        let encodedUser = config.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.username
        let encodedPass = config.password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.password
        guard let xcURL = URL(string: "\(baseURL)/player_api.php?username=\(encodedUser)&password=\(encodedPass)") else { return false }

        let (_, xcResponse) = try await session.data(for: URLRequest(url: xcURL))
        guard let httpResponse = xcResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else { return false }

        // XC auth succeeded — mark as authenticated without JWT tokens
        useApiKeyAuth = false
        useOutputEndpoints = true
        isAuthenticated = true
        return true
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        useApiKeyAuth = false
        isAuthenticated = false
    }

    // MARK: - User Info

    private struct UserMeResponse: Decodable {
        let user_level: Int
    }

    func fetchUserLevel() async throws -> Int {
        guard !config.isDemoMode else { return 10 }
        // XC-only users have no JWT/API key — they are always streamers (level 0)
        if useOutputEndpoints && accessToken == nil {
            return 0
        }
        guard let url = URL(string: "\(baseURL)/api/accounts/users/me/") else {
            throw PVRClientError.invalidResponse
        }
        let response: UserMeResponse = try await authenticatedRequest(url)
        return response.user_level
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
        if useApiKeyAuth {
            request.setValue(accessToken, forHTTPHeaderField: "X-API-Key")
        } else {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        do {
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                if useApiKeyAuth {
                    // API key auth doesn't support refresh — re-authenticate
                    isAuthenticated = false
                    try await authenticate()
                    return try await authenticatedRequest(url, method: method, body: body)
                }
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
        if useApiKeyAuth {
            request.setValue(accessToken, forHTTPHeaderField: "X-API-Key")
        } else {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                if useApiKeyAuth {
                    isAuthenticated = false
                    try await authenticate()
                    try await authenticatedRequestNoContent(url, method: method)
                    return
                }
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
        if useOutputEndpoints {
            if !config.password.isEmpty && !config.username.isEmpty && config.apiKey.isEmpty {
                return try await getChannelsFromXC()
            }
            return try await getChannelsFromM3U()
        }
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

    func getChannelProfiles() async throws -> [ChannelProfile] {
        guard !config.isDemoMode else { return DemoDataProvider.channelProfiles }
        if useOutputEndpoints { return [] }
        guard let url = URL(string: "\(baseURL)/api/channels/profiles/") else {
            throw PVRClientError.invalidResponse
        }
        let profiles: [ChannelProfile] = try await fetchAllPages(url)
        return profiles
    }

    func getChannelGroups() async throws -> [ChannelGroup] {
        guard !config.isDemoMode else { return DemoDataProvider.channelGroups }
        if useOutputEndpoints { return outputChannelGroups }
        guard let url = URL(string: "\(baseURL)/api/channels/groups/") else {
            throw PVRClientError.invalidResponse
        }
        return try await fetchAllPages(url)
    }

    // MARK: - EPG / Listings

    func getListings(channelId: Int) async throws -> [Program] {
        guard !config.isDemoMode else { return DemoDataProvider.listings(for: channelId) }

        guard let url = URL(string: "\(baseURL)/api/epg/programs/?page_size=50000") else {
            throw PVRClientError.invalidResponse
        }

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
        if useOutputEndpoints {
            return try await getAllListingsFromEPG(channels: channels)
        }

        if !isAuthenticated {
            try await authenticate()
        }

        guard let url = URL(string: "\(baseURL)/api/epg/programs/?page_size=50000") else {
            throw PVRClientError.invalidResponse
        }

        let allPrograms: [DispatcharrProgram] = try await fetchAllPages(url, maxPages: 50)

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
            channel: String(channelId),
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

        if useOutputEndpoints {
            // XC credentials: use /live/{user}/{pass}/{id}
            if !config.password.isEmpty && !config.username.isEmpty && config.apiKey.isEmpty {
                let encodedPass = config.password.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.password
                guard let url = URL(string: "\(baseURL)/live/\(config.username)/\(encodedPass)/\(channelId)") else {
                    throw PVRClientError.invalidResponse
                }
                return url
            }
            // API key: use proxy UUID (already populated from M3U)
            guard let uuid = channelIdToUUID[channelId] else {
                throw PVRClientError.apiError("No stream UUID for channel \(channelId)")
            }
            guard let url = URL(string: "\(baseURL)/proxy/ts/stream/\(uuid)") else {
                throw PVRClientError.invalidResponse
            }
            return url
        }

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
        if let urlString = channelLogoURLs[channelId], let url = URL(string: urlString) {
            return url
        }
        guard let logoId = channelIdToLogoId[channelId],
              let token = accessToken else { return nil }
        if useApiKeyAuth {
            return URL(string: "\(baseURL)/api/channels/logos/\(logoId)/cache/?api_key=\(token)")
        }
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

    // MARK: - M3U / XC / XMLTV Parsers (Streamer endpoints)

    /// Fetch channels from the unauthenticated M3U output endpoint
    private func getChannelsFromM3U() async throws -> [Channel] {
        guard let url = URL(string: "\(baseURL)/output/m3u?tvg_id_source=channel_number") else {
            throw PVRClientError.invalidResponse
        }

        let start = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PVRClientError.invalidResponse
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw PVRClientError.invalidResponse
        }

        let lines = content.components(separatedBy: .newlines)
        var channels: [Channel] = []
        channelLogoURLs = [:]
        channelIdToUUID = [:]
        var groupSet: [String: Int] = [:] // group-title → generated ID
        var nextGroupId = 1

        let extinfPattern = try NSRegularExpression(pattern: #"#EXTINF:[^,]*,(.*)"#)
        let attrPattern = try NSRegularExpression(pattern: #"(\w[\w-]*)="([^"]*)""#)

        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1

            guard line.hasPrefix("#EXTINF:") else { continue }

            // Extract attributes
            let fullRange = NSRange(line.startIndex..., in: line)
            var attrs: [String: String] = [:]
            var channelName = ""

            if let nameMatch = extinfPattern.firstMatch(in: line, range: fullRange),
               let nameRange = Range(nameMatch.range(at: 1), in: line) {
                channelName = String(line[nameRange])
            }

            for match in attrPattern.matches(in: line, range: fullRange) {
                if let keyRange = Range(match.range(at: 1), in: line),
                   let valRange = Range(match.range(at: 2), in: line) {
                    attrs[String(line[keyRange])] = String(line[valRange])
                }
            }

            // Find stream URL (next non-# non-empty line)
            var streamURL: String?
            while i < lines.count {
                let nextLine = lines[i].trimmingCharacters(in: .whitespaces)
                i += 1
                if nextLine.isEmpty || nextLine.hasPrefix("#") { continue }
                streamURL = nextLine
                break
            }

            let tvgId = attrs["tvg-id"]
            let tvgName = attrs["tvg-name"] ?? channelName
            let tvgLogo = attrs["tvg-logo"]
            let tvgChno = attrs["tvg-chno"].flatMap { Int($0) }
            let groupTitle = attrs["group-title"]

            let chno = tvgChno ?? (Int(tvgId ?? "") ?? channels.count + 1)

            // Resolve group ID
            var groupId: Int?
            if let groupTitle, !groupTitle.isEmpty {
                if let existing = groupSet[groupTitle] {
                    groupId = existing
                } else {
                    groupId = nextGroupId
                    groupSet[groupTitle] = nextGroupId
                    nextGroupId += 1
                }
            }

            // Extract UUID from proxy stream URL if available
            if let streamURL, let uuidRange = streamURL.range(of: "/proxy/ts/stream/") {
                let uuid = String(streamURL[uuidRange.upperBound...])
                channelIdToUUID[chno] = uuid
            }

            if let tvgLogo, !tvgLogo.isEmpty {
                channelLogoURLs[chno] = tvgLogo
            }

            channels.append(Channel(
                id: chno,
                name: tvgName,
                number: chno,
                hasIcon: tvgLogo != nil && !tvgLogo!.isEmpty,
                streamURL: streamURL,
                groupId: groupId,
                logoURL: tvgLogo
            ))
        }

        // Build channel groups
        outputChannelGroups = groupSet.map { ChannelGroup(id: $0.value, name: $0.key) }
            .sorted { $0.id < $1.id }

        print("[Dispatcharr] Parsed \(channels.count) channels from M3U in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000))ms")
        return channels
    }

    /// Fetch channels from the XC live streams API
    private func getChannelsFromXC() async throws -> [Channel] {
        let encodedUser = config.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.username
        let encodedPass = config.password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.password

        guard let url = URL(string: "\(baseURL)/player_api.php?username=\(encodedUser)&password=\(encodedPass)&action=get_live_streams") else {
            throw PVRClientError.invalidResponse
        }

        let start = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PVRClientError.invalidResponse
        }

        let streams = try JSONDecoder().decode([XCLiveStream].self, from: data)

        channelLogoURLs = [:]
        var channels: [Channel] = []

        for stream in streams {
            if let icon = stream.streamIcon, !icon.isEmpty {
                channelLogoURLs[stream.streamId] = icon
            }

            let groupId = stream.categoryId.flatMap { Int($0) }

            channels.append(Channel(
                id: stream.streamId,
                name: stream.name,
                number: stream.num,
                hasIcon: stream.streamIcon != nil && !stream.streamIcon!.isEmpty,
                streamURL: nil,
                groupId: groupId,
                logoURL: stream.streamIcon
            ))
        }

        // Fetch categories for group names
        if let catURL = URL(string: "\(baseURL)/player_api.php?username=\(encodedUser)&password=\(encodedPass)&action=get_live_categories") {
            do {
                let (catData, catResponse) = try await session.data(for: URLRequest(url: catURL))
                if let httpCatResponse = catResponse as? HTTPURLResponse,
                   (200...299).contains(httpCatResponse.statusCode) {
                    let categories = try JSONDecoder().decode([XCCategory].self, from: catData)
                    outputChannelGroups = categories.compactMap { cat in
                        guard let id = Int(cat.categoryId) else { return nil }
                        return ChannelGroup(id: id, name: cat.categoryName)
                    }
                }
            } catch {
                // Non-fatal: groups just won't have names
                outputChannelGroups = []
            }
        }

        print("[Dispatcharr] Parsed \(channels.count) channels from XC API in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000))ms")
        return channels
    }

    /// Fetch EPG data from the XMLTV output endpoint
    private func getAllListingsFromEPG(channels: [Channel]) async throws -> [Int: [Program]] {
        guard let url = URL(string: "\(baseURL)/output/epg?tvg_id_source=channel_number") else {
            throw PVRClientError.invalidResponse
        }

        let start = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PVRClientError.invalidResponse
        }

        // Build channel number lookup from the channels array
        let channelNumberToId: [String: Int] = Dictionary(
            channels.map { (String($0.number), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        let delegate = XMLTVParserDelegate(channelNumberToId: channelNumberToId)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        print("[Dispatcharr] Parsed \(delegate.programs.values.reduce(0) { $0 + $1.count }) programs from XMLTV in \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000))ms")
        return delegate.programs
    }
}

// MARK: - XMLTV Parser

private class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    var programs: [Int: [Program]] = [:]
    private let channelNumberToId: [String: Int]

    private var currentElement = ""
    private var currentChannelAttr = ""
    private var currentStartAttr = ""
    private var currentStopAttr = ""
    private var currentTitle = ""
    private var currentSubTitle = ""
    private var currentDesc = ""
    private var currentCategory = ""
    private var inProgramme = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(channelNumberToId: [String: Int]) {
        self.channelNumberToId = channelNumberToId
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName

        if elementName == "programme" {
            inProgramme = true
            currentChannelAttr = attributeDict["channel"] ?? ""
            currentStartAttr = attributeDict["start"] ?? ""
            currentStopAttr = attributeDict["stop"] ?? ""
            currentTitle = ""
            currentSubTitle = ""
            currentDesc = ""
            currentCategory = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inProgramme else { return }
        switch currentElement {
        case "title": currentTitle += string
        case "sub-title": currentSubTitle += string
        case "desc": currentDesc += string
        case "category": currentCategory += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "programme" {
            inProgramme = false

            guard let channelId = channelNumberToId[currentChannelAttr],
                  let startDate = Self.dateFormatter.date(from: currentStartAttr),
                  let stopDate = Self.dateFormatter.date(from: currentStopAttr),
                  stopDate > startDate else {
                return
            }

            let idString = "\(currentChannelAttr)-\(currentStartAttr)"
            let programId = abs(idString.hashValue)

            let genres: [String]? = currentCategory.isEmpty ? nil : [currentCategory]

            let program = Program(
                id: programId,
                name: currentTitle,
                subtitle: currentSubTitle.isEmpty ? nil : currentSubTitle,
                desc: currentDesc.isEmpty ? nil : currentDesc,
                start: Int(startDate.timeIntervalSince1970),
                end: Int(stopDate.timeIntervalSince1970),
                genres: genres,
                channelId: channelId
            )

            programs[channelId, default: []].append(program)
        }

        if elementName != "programme" {
            currentElement = ""
        }
    }
}

// MARK: - XC API Models

private nonisolated struct XCLiveStream: Decodable {
    let num: Int
    let name: String
    let streamId: Int
    let streamIcon: String?
    let categoryId: String?

    enum CodingKeys: String, CodingKey {
        case num, name
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case categoryId = "category_id"
    }
}

private nonisolated struct XCCategory: Decodable {
    let categoryId: String
    let categoryName: String

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
    }
}

// MARK: - API Response Models

private nonisolated struct TokenResponse: Decodable {
    let access: String
    let refresh: String
}

private nonisolated struct TokenRefreshResponse: Decodable {
    let access: String
}

/// Flexible list response that handles array, { results: [] }, or { data: [] }
nonisolated struct DispatcharrListResponse<T: Decodable>: Decodable {
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

nonisolated struct DispatcharrChannel: Decodable {
    let id: Int
    let name: String
    let channelNumber: Double?
    let tvgId: String?
    let logoId: Int?
    let uuid: String?
    let epgDataId: Int?
    let channelGroupId: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case channelNumber = "channel_number"
        case tvgId = "tvg_id"
        case logoId = "logo_id"
        case uuid
        case epgDataId = "epg_data_id"
        case channelGroupId = "channel_group_id"
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

        // channel_group_id can be Int or String
        if let intGroup = try? container.decode(Int.self, forKey: .channelGroupId) {
            channelGroupId = intGroup
        } else if let stringGroup = try? container.decodeIfPresent(String.self, forKey: .channelGroupId),
                  let parsed = Int(stringGroup) {
            channelGroupId = parsed
        } else {
            channelGroupId = nil
        }

    }

    func toChannel() -> Channel {
        Channel(
            id: id,
            name: name,
            number: Int(channelNumber ?? 0),
            hasIcon: logoId != nil,
            groupId: channelGroupId
        )
    }
}

private nonisolated struct DispatcharrEPGData: Decodable, Sendable {
    let id: Int
    let tvgId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case tvgId = "tvg_id"
    }
}

nonisolated struct DispatcharrProgram: Decodable, Sendable {
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

nonisolated struct DispatcharrRecording: Decodable {
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

nonisolated struct DispatcharrCustomProperties: Codable {
    let program: DispatcharrProgramRef?
}

nonisolated struct DispatcharrProgramRef: Codable {
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

nonisolated struct M3UAccount: Decodable, Identifiable {
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

nonisolated struct ProxyStatusResponse: Decodable {
    let count: Int?
    let channels: [ProxyChannelStatus]?
}

nonisolated struct ProxyChannelStatus: Decodable, Identifiable {
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

nonisolated struct ProxyClientInfo: Decodable, Identifiable {
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

private nonisolated struct DispatcharrRecordingRequest: Encodable {
    let startTime: String
    let endTime: String
    let channel: String
    let customProperties: DispatcharrCustomProperties

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case channel
        case customProperties = "custom_properties"
    }
}
