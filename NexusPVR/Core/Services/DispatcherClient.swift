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
    private var authInProgress: Task<Void, Error>?
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
    /// In-memory map of synthetic recurring IDs -> Dispatcharr series rule, used for cancel.
    private var seriesRuleIndex: [Int: DispatcharrSeriesRuleResponseItem] = [:]

    init(config: ServerConfig? = nil) {
        self.config = config ?? ServerConfig.load()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
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

    // MARK: - Network Logging

    private func sanitizePath(_ url: URL?) -> String {
        guard let url else { return "?" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let sensitiveKeys: Set<String> = ["username", "password", "api_key", "token"]
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

    private static let retryDelays: [Double] = [0.5, 1.0, 2.0, 4.0, 6.0]
    private static let maxAttempts = 5
    private static let retryableHTTPStatusCodes: Set<Int> = [408, 425, 429, 500, 502, 503, 504]
    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed,
        .cannotLoadFromNetwork,
        .secureConnectionFailed,
        .badServerResponse,
        .cannotParseResponse
    ]
    private static let retryablePOSIXErrorCodes: Set<POSIXErrorCode> = [
        .ECONNABORTED,
        .ECONNREFUSED,
        .ECONNRESET,
        .EPIPE,
        .ETIMEDOUT
    ]

    private func isRetryableNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return Self.retryableURLErrorCodes.contains(urlError.code)
        }
        return isRetryableNSError(error as NSError)
    }

    private func isRetryableNSError(_ error: NSError) -> Bool {
        NetworkEventLog.shared.log(NetworkEvent(
            timestamp: Date(),
            method: "RETRY",
            path: "/retryability/ns-error",
            statusCode: nil,
            isSuccess: false,
            durationMs: 0,
            responseSize: 0,
            errorDetail: "Inspecting NSError domain=\(error.domain) code=\(error.code) desc=\(error.localizedDescription)"
        ))

        if error.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: error.code)
            if Self.retryableURLErrorCodes.contains(code) {
                return true
            }
        }

        if error.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(error.code)),
           Self.retryablePOSIXErrorCodes.contains(code) {
            return true
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isRetryableNSError(underlying)
        }

        NetworkEventLog.shared.log(NetworkEvent(
            timestamp: Date(),
            method: "RETRY",
            path: "/retryability/ns-error",
            statusCode: nil,
            isSuccess: false,
            durationMs: 0,
            responseSize: 0,
            errorDetail: "NSError is not retryable; returning false for domain=\(error.domain) code=\(error.code)"
        ))
        return false
    }

    private func retryDelay(for attempt: Int) -> Double {
        let base = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
        return base + Double(attempt) * 0.15
    }

    private func networkErrorDetail(_ error: Error, attempt: Int, willRetry: Bool) -> String {
        let nsError = error as NSError
        var parts: [String] = []

        if let urlError = error as? URLError {
            parts.append("URLError(\(urlError.code.rawValue): \(urlError.code))")
        } else if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            parts.append("URLError(\(nsError.code): \(code))")
        } else {
            parts.append("\(nsError.domain)(\(nsError.code))")
        }

        if let nwPath = nsError.userInfo["NSURLErrorNWPathKey"] {
            parts.append("nwPath=\(nwPath)")
        } else if let legacyPath = nsError.userInfo["_NSURLErrorNWPathKey"] {
            parts.append("nwPath=\(legacyPath)")
        }

        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] {
            parts.append("url=\(failingURL)")
        } else if let failingURLString = nsError.userInfo["NSErrorFailingURLStringKey"] {
            parts.append("url=\(failingURLString)")
        }

        parts.append(error.localizedDescription)
        if willRetry {
            parts.append("(retrying \(attempt)/\(Self.maxAttempts))")
        }
        return parts.joined(separator: " ")
    }

    private func loggedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = sanitizePath(request.url)
        var lastError: Error?

        for attempt in 1...Self.maxAttempts {
            let start = CFAbsoluteTimeGetCurrent()
            NetworkEventLog.shared.log(NetworkEvent(
                timestamp: Date(), method: method, path: path,
                statusCode: nil, isSuccess: true,
                durationMs: 0, responseSize: 0,
                errorDetail: "Request started (attempt \(attempt)/\(Self.maxAttempts))"
            ))
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                let ok = status.map { (200...399).contains($0) } ?? false
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let shouldRetryHTTP = status.map { Self.retryableHTTPStatusCodes.contains($0) } ?? false

                if shouldRetryHTTP && attempt < Self.maxAttempts {
                    NetworkEventLog.shared.log(NetworkEvent(
                        timestamp: Date(), method: method, path: path,
                        statusCode: status, isSuccess: false,
                        durationMs: ms, responseSize: data.count,
                        errorDetail: "Transient HTTP \(status ?? -1), retrying \(attempt)/\(Self.maxAttempts)"
                    ))
                    let retryDelayNs = UInt64(retryDelay(for: attempt) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: retryDelayNs)
                    continue
                }

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

                let isTransient = isRetryableNetworkError(error)
                let willRetry = isTransient && attempt < Self.maxAttempts
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(), method: method, path: path,
                    statusCode: nil, isSuccess: false,
                    durationMs: ms, responseSize: 0,
                    errorDetail: networkErrorDetail(error, attempt: attempt, willRetry: willRetry)
                ))

                if willRetry {
                    let retryDelayNs = UInt64(retryDelay(for: attempt) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: retryDelayNs)
                    continue
                }

                throw error
            }
        }

        throw lastError!
    }

    private func loggedData(from url: URL) async throws -> (Data, URLResponse) {
        try await loggedData(for: URLRequest(url: url))
    }

    // MARK: - Authentication

    func authenticate() async throws {
        guard !config.isDemoMode else { isAuthenticated = true; return }

        guard config.isConfigured else {
            throw PVRClientError.notConfigured
        }

        // Coalesce concurrent auth calls — only one in-flight at a time
        if let existing = authInProgress {
            return try await existing.value
        }

        let task = Task {
            try await self.authenticateImpl()
        }
        authInProgress = task
        defer { authInProgress = nil }
        try await task.value
    }

    private func authenticateImpl() async throws {
        // API key auth: use X-API-Key header, no JWT flow needed
        if !config.apiKey.isEmpty {
            isConnecting = true
            defer { isConnecting = false }

            NetworkEventLog.shared.log(NetworkEvent(
                timestamp: Date(),
                method: "AUTH",
                path: "/dispatcharr/api-key",
                statusCode: nil,
                isSuccess: true,
                durationMs: 0,
                responseSize: 0,
                errorDetail: "Starting Dispatcharr API key authentication against \(baseURL)"
            ))

            // Probe /api/accounts/users/me/ — accessible to all authenticated users regardless of role
            guard let url = URL(string: "\(baseURL)/api/accounts/users/me/") else {
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(),
                    method: "AUTH",
                    path: "/dispatcharr/api-key",
                    statusCode: nil,
                    isSuccess: false,
                    durationMs: 0,
                    responseSize: 0,
                    errorDetail: "Invalid URL for API key probe"
                ))
                throw PVRClientError.invalidResponse
            }

            var request = URLRequest(url: url)
            request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (_, response) = try await loggedData(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    NetworkEventLog.shared.log(NetworkEvent(
                        timestamp: Date(),
                        method: "AUTH",
                        path: "/dispatcharr/api-key",
                        statusCode: nil,
                        isSuccess: false,
                        durationMs: 0,
                        responseSize: 0,
                        errorDetail: "API key probe returned a non-HTTP response"
                    ))
                    throw PVRClientError.invalidResponse
                }
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    NetworkEventLog.shared.log(NetworkEvent(
                        timestamp: Date(),
                        method: "AUTH",
                        path: "/dispatcharr/api-key",
                        statusCode: httpResponse.statusCode,
                        isSuccess: false,
                        durationMs: 0,
                        responseSize: 0,
                        errorDetail: "API key rejected"
                    ))
                    throw PVRClientError.authenticationFailed
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    NetworkEventLog.shared.log(NetworkEvent(
                        timestamp: Date(),
                        method: "AUTH",
                        path: "/dispatcharr/api-key",
                        statusCode: httpResponse.statusCode,
                        isSuccess: false,
                        durationMs: 0,
                        responseSize: 0,
                        errorDetail: "Unexpected API key auth status"
                    ))
                    throw PVRClientError.invalidResponse
                }
                accessToken = config.apiKey
                refreshToken = nil
                useApiKeyAuth = true
                isAuthenticated = true
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(),
                    method: "AUTH",
                    path: "/dispatcharr/api-key",
                    statusCode: httpResponse.statusCode,
                    isSuccess: true,
                    durationMs: 0,
                    responseSize: 0,
                    errorDetail: "API key authentication succeeded"
                ))
            } catch let error as PVRClientError {
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(),
                    method: "AUTH",
                    path: "/dispatcharr/api-key",
                    statusCode: nil,
                    isSuccess: false,
                    durationMs: 0,
                    responseSize: 0,
                    errorDetail: "API key authentication error: \(error.localizedDescription)"
                ))
                throw error
            } catch {
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(),
                    method: "AUTH",
                    path: "/dispatcharr/api-key",
                    statusCode: nil,
                    isSuccess: false,
                    durationMs: 0,
                    responseSize: 0,
                    errorDetail: "API key authentication threw unexpected error: \(error.localizedDescription)"
                ))
                throw PVRClientError.networkError(error)
            }
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        NetworkEventLog.shared.log(NetworkEvent(
            timestamp: Date(),
            method: "AUTH",
            path: "/dispatcharr/jwt",
            statusCode: nil,
            isSuccess: true,
            durationMs: 0,
            responseSize: 0,
            errorDetail: "Starting Dispatcharr JWT authentication against \(baseURL)"
        ))

        guard let url = URL(string: "\(baseURL)/api/accounts/token/") else {
            NetworkEventLog.shared.log(NetworkEvent(
                timestamp: Date(),
                method: "AUTH",
                path: "/dispatcharr/jwt",
                statusCode: nil,
                isSuccess: false,
                durationMs: 0,
                responseSize: 0,
                errorDetail: "Invalid URL for token endpoint"
            ))
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
            let (data, response) = try await loggedData(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(),
                    method: "AUTH",
                    path: "/dispatcharr/jwt",
                    statusCode: nil,
                    isSuccess: false,
                    durationMs: 0,
                    responseSize: data.count,
                    errorDetail: "Token endpoint returned a non-HTTP response"
                ))
                throw PVRClientError.invalidResponse
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 400 {
                // JWT failed — try XC API as fallback (password may be XC, not Django)
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(),
                    method: "AUTH",
                    path: "/dispatcharr/jwt",
                    statusCode: httpResponse.statusCode,
                    isSuccess: false,
                    durationMs: 0,
                    responseSize: data.count,
                    errorDetail: "JWT auth rejected, trying XC fallback"
                ))
                if try await authenticateViaXC() { return }
                throw PVRClientError.authenticationFailed
            }

            guard httpResponse.statusCode == 200 else {
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(),
                    method: "AUTH",
                    path: "/dispatcharr/jwt",
                    statusCode: httpResponse.statusCode,
                    isSuccess: false,
                    durationMs: 0,
                    responseSize: data.count,
                    errorDetail: "Unexpected token endpoint status"
                ))
                throw PVRClientError.invalidResponse
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            accessToken = tokenResponse.access
            refreshToken = tokenResponse.refresh
            useApiKeyAuth = false
            isAuthenticated = true
            NetworkEventLog.shared.log(NetworkEvent(
                timestamp: Date(),
                method: "AUTH",
                path: "/dispatcharr/jwt",
                statusCode: httpResponse.statusCode,
                isSuccess: true,
                durationMs: 0,
                responseSize: data.count,
                errorDetail: "JWT authentication succeeded"
            ))
        } catch let error as PVRClientError {
            NetworkEventLog.shared.log(NetworkEvent(
                timestamp: Date(),
                method: "AUTH",
                path: "/dispatcharr/jwt",
                statusCode: nil,
                isSuccess: false,
                durationMs: 0,
                responseSize: 0,
                errorDetail: "JWT authentication error: \(error.localizedDescription)"
            ))
            throw error
        } catch {
            NetworkEventLog.shared.log(NetworkEvent(
                timestamp: Date(),
                method: "AUTH",
                path: "/dispatcharr/jwt",
                statusCode: nil,
                isSuccess: false,
                durationMs: 0,
                responseSize: 0,
                errorDetail: "JWT authentication threw unexpected error: \(error.localizedDescription)"
            ))
            throw PVRClientError.networkError(error)
        }
    }

    /// Try authenticating via XC API (for streamer users with XC credentials)
    private func authenticateViaXC() async throws -> Bool {
        guard !config.username.isEmpty, !config.password.isEmpty else { return false }
        let encodedUser = config.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.username
        let encodedPass = config.password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.password
        guard let xcURL = URL(string: "\(baseURL)/player_api.php?username=\(encodedUser)&password=\(encodedPass)") else { return false }

        NetworkEventLog.shared.log(NetworkEvent(
            timestamp: Date(),
            method: "AUTH",
            path: "/dispatcharr/xc",
            statusCode: nil,
            isSuccess: true,
            durationMs: 0,
            responseSize: 0,
            errorDetail: "Attempting XC fallback authentication"
        ))

        let (_, xcResponse) = try await loggedData(from: xcURL)
        guard let httpResponse = xcResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            NetworkEventLog.shared.log(NetworkEvent(
                timestamp: Date(),
                method: "AUTH",
                path: "/dispatcharr/xc",
                statusCode: (xcResponse as? HTTPURLResponse)?.statusCode,
                isSuccess: false,
                durationMs: 0,
                responseSize: 0,
                errorDetail: "XC fallback authentication failed"
            ))
            return false
        }

        // XC auth succeeded — mark as authenticated without JWT tokens
        useApiKeyAuth = false
        useOutputEndpoints = true
        isAuthenticated = true
        NetworkEventLog.shared.log(NetworkEvent(
            timestamp: Date(),
            method: "AUTH",
            path: "/dispatcharr/xc",
            statusCode: httpResponse.statusCode,
            isSuccess: true,
            durationMs: 0,
            responseSize: 0,
            errorDetail: "XC fallback authentication succeeded"
        ))
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

        let (data, response) = try await loggedData(for: request)

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
        let data = try await authenticatedRequestData(url, method: method, body: body)
        do {
            return try await Self.decodeOffMainActor(data)
        } catch is DecodingError {
            throw PVRClientError.invalidResponse
        }
    }

    private func authenticatedRequestData(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
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
            let (data, response) = try await loggedData(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PVRClientError.invalidResponse
            }

            if httpResponse.statusCode == 401 {
                if useApiKeyAuth {
                    // API key auth doesn't support refresh — re-authenticate
                    isAuthenticated = false
                    try await authenticate()
                    return try await authenticatedRequestData(url, method: method, body: body)
                }
                // Try refreshing the token
                do {
                    try await refreshAccessToken()
                    return try await authenticatedRequestData(url, method: method, body: body)
                } catch {
                    // Refresh failed, full re-auth
                    isAuthenticated = false
                    try await authenticate()
                    return try await authenticatedRequestData(url, method: method, body: body)
                }
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let detail = dispatcharrAPIErrorMessage(from: data)
                let fallbackBody = String(data: Data(data.prefix(512)), encoding: .utf8) ?? ""
                let message = detail ?? (fallbackBody.isEmpty ? "Request failed with status \(httpResponse.statusCode)" : fallbackBody)
                NetworkEventLog.shared.log(NetworkEvent(
                    timestamp: Date(),
                    method: method,
                    path: sanitizePath(url),
                    statusCode: httpResponse.statusCode,
                    isSuccess: false,
                    durationMs: 0,
                    responseSize: data.count,
                    errorDetail: message
                ))
                throw PVRClientError.apiError("HTTP \(httpResponse.statusCode): \(message)")
            }

            return data
        } catch let error as PVRClientError {
            throw error
        } catch {
            throw PVRClientError.networkError(error)
        }
    }

    private func dispatcharrAPIErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let payload = try? JSONDecoder().decode(DispatcharrAPIErrorResponse.self, from: data) else { return nil }
        return payload.bestMessage
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

        let (_, response) = try await loggedData(for: request)

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
        // Fetch page 1 to get total count and page size
        let firstResponse: DispatcharrListResponse<T> = try await authenticatedRequest(url)
        var allItems = firstResponse.allItems

        guard let totalCount = firstResponse.count, totalCount > allItems.count else {
            return allItems
        }

        // Determine page size from the URL or from what we received
        let pageSize = allItems.count
        guard pageSize > 0 else { return allItems }
        let totalPages = (totalCount + pageSize - 1) / pageSize
        let pagesToFetch = maxPages > 0 ? min(totalPages, maxPages) : totalPages

        if pagesToFetch <= 1 { return allItems }

        // Fetch remaining pages concurrently
        let results = try await withThrowingTaskGroup(of: (Int, [T]).self) { group in
            for page in 2...pagesToFetch {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                var queryItems = components.queryItems ?? []
                queryItems.removeAll { $0.name == "page" }
                queryItems.append(URLQueryItem(name: "page", value: String(page)))
                components.queryItems = queryItems

                group.addTask {
                    let response: DispatcharrListResponse<T> = try await self.authenticatedRequest(components.url!)
                    return (page, response.allItems)
                }
            }

            var pageResults = [(Int, [T])]()
            for try await result in group {
                pageResults.append(result)
            }
            return pageResults.sorted { $0.0 < $1.0 }
        }

        for (_, items) in results {
            allItems.append(contentsOf: items)
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
        if useOutputEndpoints { return ([], [], []) }
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
        let program = try await fetchProgramDetails(eventId: eventId)
        let channelId = try resolveChannelId(for: program, fallbackChannelId: nil)
        try await createRecording(
            startTime: program.startTime,
            endTime: program.endTime,
            channelId: channelId,
            programRef: DispatcharrProgramRef(
                id: program.idWasSynthetic ? nil : program.id,
                startTime: program.startTime,
                endTime: program.endTime,
                title: program.title,
                subTitle: program.subTitle,
                description: program.description,
                tvgId: program.tvgId,
                bannerURL: program.bannerURL
            )
        )
    }

    func scheduleRecording(program: Program, channel: Channel?) async throws {
        guard !config.isDemoMode else { DemoDataProvider.scheduleRecording(eventId: program.id); return }
        let fallbackChannelId = channel?.id ?? program.channelId

        do {
            let fetched = try await fetchProgramDetails(eventId: program.id)
            let channelId = try resolveChannelId(for: fetched, fallbackChannelId: fallbackChannelId)
            try await createRecording(
                startTime: fetched.startTime,
                endTime: fetched.endTime,
                channelId: channelId,
                programRef: DispatcharrProgramRef(
                    id: fetched.idWasSynthetic ? nil : fetched.id,
                    startTime: fetched.startTime,
                    endTime: fetched.endTime,
                    title: fetched.title,
                    subTitle: fetched.subTitle,
                    description: fetched.description,
                    tvgId: fetched.tvgId,
                    bannerURL: fetched.bannerURL
                )
            )
        } catch {
            guard shouldFallbackToProgramContext(error), let fallbackChannelId else {
                throw error
            }
            try await createRecording(
                startTime: Self.iso8601String(fromUnix: program.start),
                endTime: Self.iso8601String(fromUnix: program.end),
                channelId: fallbackChannelId,
                programRef: DispatcharrProgramRef(
                    id: nil,
                    startTime: Self.iso8601String(fromUnix: program.start),
                    endTime: Self.iso8601String(fromUnix: program.end),
                    title: program.name,
                    subTitle: program.subtitle,
                    description: program.desc,
                    tvgId: nil,
                    bannerURL: program.bannerURL
                )
            )
        }
    }

    func scheduleSeriesRecording(eventId: Int) async throws {
        guard !config.isDemoMode else { DemoDataProvider.scheduleSeriesRecording(eventId: eventId); return }
        try await scheduleSeriesRecording(eventId: eventId, mode: "new")
    }

    func scheduleSeriesRecording(eventId: Int, mode: String) async throws {
        guard !config.isDemoMode else { DemoDataProvider.scheduleSeriesRecording(eventId: eventId); return }

        let normalizedMode = mode.lowercased()
        guard normalizedMode == "new" || normalizedMode == "all" else {
            throw PVRClientError.apiError("Unsupported series mode '\(mode)'. Expected 'new' or 'all'.")
        }

        let program = try await fetchProgramDetails(eventId: eventId)
        let rawTitle = program.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = SeriesInfo.parse(
            name: rawTitle,
            subtitle: program.subTitle,
            desc: program.description
        )?.seriesName ?? rawTitle
        guard !title.isEmpty else {
            throw PVRClientError.apiError("Series rule requires a valid title")
        }

        let resolvedTvgId: String? = {
            if let tvgId = program.tvgId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tvgId.isEmpty {
                return tvgId
            }
            if let channelId = program.channel {
                return tvgIdToChannelId.first(where: { $0.value == channelId })?.key
            }
            return nil
        }()

        guard let tvgId = resolvedTvgId, !tvgId.isEmpty else {
            throw PVRClientError.apiError("Series rule requires tvg_id for this channel")
        }

        guard let url = URL(string: "\(baseURL)/api/channels/series-rules/") else {
            throw PVRClientError.invalidResponse
        }

        let request = DispatcharrSeriesRuleRequest(
            mode: normalizedMode,
            title: title,
            tvgId: tvgId
        )
        let body = try JSONEncoder().encode(request)
        if let payload = Self.debugJSONString(from: body) {
            print("[Dispatcharr][SeriesRule][Request] POST /api/channels/series-rules/ payload=\(payload)")
        }
        let data = try await authenticatedRequestData(url, method: "POST", body: body)
        if let responseBody = Self.debugJSONString(from: data) {
            print("[Dispatcharr][SeriesRule][Response] POST /api/channels/series-rules/ body=\(responseBody)")
        }
        if let response: DispatcharrSeriesRulesResponse = try? await Self.decodeOffMainActor(data),
           response.success == false {
            throw PVRClientError.apiError("Series rule was not created")
        }

        // Dispatcharr requires an evaluate pass to materialize matching scheduled recordings.
        let evaluateResponse = try await evaluateSeriesRules(tvgId: tvgId, expectedTitle: title)

        // In ALL mode, ensure at least the currently selected program is scheduled immediately.
        if normalizedMode == "all", !didCreateScheduledRecording(from: evaluateResponse, expectedTitle: title) {
            try await scheduleRecording(eventId: eventId)
        }
    }

    func cancelSeriesRecording(recurringId: Int) async throws {
        guard !config.isDemoMode else { DemoDataProvider.cancelSeriesRecording(recurringId: recurringId); return }

        if let rule = seriesRuleIndex[recurringId],
           let title = rule.title,
           let tvgId = rule.tvgId {
            try await deleteSeriesRule(
                mode: (rule.mode ?? "new"),
                title: title,
                tvgId: tvgId
            )
            return
        }

        // Refresh mapping once and retry cancellation by rule ID.
        _ = try? await getRecurringRecordings()
        if let rule = seriesRuleIndex[recurringId],
           let title = rule.title,
           let tvgId = rule.tvgId {
            try await deleteSeriesRule(
                mode: (rule.mode ?? "new"),
                title: title,
                tvgId: tvgId
            )
            return
        }

        // Last-resort fallback for legacy behavior
        try await cancelRecording(recordingId: recurringId)
    }

    func getRecurringRecordings() async throws -> [RecurringRecording] {
        guard !config.isDemoMode else { return DemoDataProvider.recurringRecordings() }
        guard let url = URL(string: "\(baseURL)/api/channels/series-rules/") else {
            throw PVRClientError.invalidResponse
        }

        let data = try await authenticatedRequestData(url)
        let response: DispatcharrSeriesRulesResponse = try await Self.decodeOffMainActor(data)
        let rules = response.rules ?? []
        seriesRuleIndex.removeAll(keepingCapacity: true)

        var recurrings: [RecurringRecording] = []
        recurrings.reserveCapacity(rules.count)

        for rule in rules {
            guard let title = rule.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let tvgId = rule.tvgId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tvgId.isEmpty else { continue }

            let mode = (rule.mode ?? "new").lowercased()
            let recurringId = Self.syntheticSeriesRuleID(mode: mode, title: title, tvgId: tvgId)
            seriesRuleIndex[recurringId] = rule

            recurrings.append(
                RecurringRecording(
                    id: recurringId,
                    name: title,
                    channelID: tvgIdToChannelId[tvgId],
                    channel: nil,
                    enabled: response.success ?? true
                )
            )
        }

        return recurrings
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

    private func fetchProgramDetails(eventId: Int) async throws -> DispatcharrProgram {
        guard let programURL = URL(string: "\(baseURL)/api/epg/programs/\(eventId)/") else {
            throw PVRClientError.invalidResponse
        }
        return try await authenticatedRequest(programURL)
    }

    private func resolveChannelId(for program: DispatcharrProgram, fallbackChannelId: Int?) throws -> Int {
        if let directId = program.channel {
            return directId
        }
        if let tvgId = program.tvgId, let mappedId = tvgIdToChannelId[tvgId] {
            return mappedId
        }
        if let fallbackChannelId {
            return fallbackChannelId
        }
        throw PVRClientError.apiError("Cannot determine channel for this program")
    }

    private func createRecording(startTime: String, endTime: String, channelId: Int, programRef: DispatcharrProgramRef?) async throws {
        guard let url = URL(string: "\(baseURL)/api/channels/recordings/") else {
            throw PVRClientError.invalidResponse
        }

        let recordingRequest = DispatcharrRecordingRequest(
            startTime: startTime,
            endTime: endTime,
            channel: channelId,
            customProperties: DispatcharrCustomProperties(program: programRef)
        )
        let body = try JSONEncoder().encode(recordingRequest)
        let data = try await authenticatedRequestData(url, method: "POST", body: body)
        let _: DispatcharrRecording? = try? await Self.decodeOffMainActor(data)
    }

    private func shouldFallbackToProgramContext(_ error: Error) -> Bool {
        if case let PVRClientError.apiError(message) = error {
            let lowercased = message.lowercased()
            return lowercased.contains("no programdata matches") ||
                lowercased.contains("cannot determine channel")
        }
        if case PVRClientError.invalidResponse = error {
            return true
        }
        return false
    }

    private nonisolated static func iso8601String(fromUnix timestamp: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private func evaluateSeriesRules(tvgId: String, expectedTitle: String) async throws -> DispatcharrSeriesRulesEvaluateResponse? {
        guard let url = URL(string: "\(baseURL)/api/channels/series-rules/evaluate/") else {
            throw PVRClientError.invalidResponse
        }

        let request = DispatcharrSeriesRulesEvaluateRequest(tvgId: tvgId)
        let body = try JSONEncoder().encode(request)
        if let payload = Self.debugJSONString(from: body) {
            print("[Dispatcharr][SeriesRule][Request] POST /api/channels/series-rules/evaluate/ payload=\(payload)")
        }
        let data = try await authenticatedRequestData(url, method: "POST", body: body)
        if let responseBody = Self.debugJSONString(from: data) {
            print("[Dispatcharr][SeriesRule][Response] POST /api/channels/series-rules/evaluate/ body=\(responseBody)")
        }

        guard let response: DispatcharrSeriesRulesEvaluateResponse = try? await Self.decodeOffMainActor(data) else {
            return nil
        }
        guard response.success != false else {
            throw PVRClientError.apiError("Series rule evaluation failed")
        }

        _ = expectedTitle
        return response
    }

    private func didCreateScheduledRecording(from response: DispatcharrSeriesRulesEvaluateResponse?, expectedTitle: String) -> Bool {
        guard let response else { return false }
        if (response.scheduled ?? 0) > 0 { return true }
        guard let details = response.details, !details.isEmpty else { return false }

        let expected = expectedTitle.lowercased()
        if details.contains(where: { ($0.title?.lowercased() == expected) && (($0.created ?? 0) > 0) }) {
            return true
        }
        return details.contains(where: { ($0.created ?? 0) > 0 })
    }

    private func deleteSeriesRule(mode: String, title: String, tvgId: String) async throws {
        let request = DispatcharrSeriesRuleRequest(
            mode: mode.lowercased(),
            title: title,
            tvgId: tvgId
        )
        let body = try JSONEncoder().encode(request)

        let attempts: [(path: String, method: String)] = [
            ("/api/channels/series-rules/", "DELETE"),
            ("/api/channels/series-rules/delete/", "POST"),
            ("/api/channels/series-rules/remove/", "POST")
        ]

        var lastError: Error?
        for attempt in attempts {
            do {
                guard let url = URL(string: "\(baseURL)\(attempt.path)") else {
                    throw PVRClientError.invalidResponse
                }
                if let payload = Self.debugJSONString(from: body) {
                    print("[Dispatcharr][SeriesRule][Request] \(attempt.method) \(attempt.path) payload=\(payload)")
                }
                let data = try await authenticatedRequestData(url, method: attempt.method, body: body)
                if let responseBody = Self.debugJSONString(from: data) {
                    print("[Dispatcharr][SeriesRule][Response] \(attempt.method) \(attempt.path) body=\(responseBody)")
                }
                return
            } catch {
                lastError = error
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("[Dispatcharr][SeriesRule][Error] \(attempt.method) \(attempt.path) error=\(message)")
            }
        }

        throw lastError ?? PVRClientError.apiError("Failed to delete series rule")
    }

    private nonisolated static func debugJSONString(from data: Data) -> String? {
        guard !data.isEmpty else { return "{}" }
        if let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
           let text = String(data: pretty, encoding: .utf8) {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func syntheticSeriesRuleID(mode: String, title: String, tvgId: String) -> Int {
        // Stable FNV-1a 32-bit hash for deterministic IDs across launches.
        let key = "\(mode.lowercased())|\(title.lowercased())|\(tvgId.lowercased())"
        var hash: UInt32 = 0x811C9DC5
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return Int(hash & 0x7FFF_FFFF)
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

    func streamAuthHeaders() -> [String: String] {
        guard let token = accessToken else { return [:] }
        if useApiKeyAuth {
            return ["X-API-Key": token]
        }
        return ["Authorization": "Bearer \(token)"]
    }

    func channelIconURL(channelId: Int) throws -> URL? {
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

    func recordingArtworkURL(recordingId: Int, fanart: Bool) -> URL? {
        guard !config.isDemoMode else { return DemoDataProvider.recordingArtworkURL(recordingId: recordingId, fanart: fanart) }
        return nil
    }

    // MARK: - Proxy Status

    func getProxyStatus() async throws -> ProxyStatusResponse {
        guard !config.isDemoMode else { return ProxyStatusResponse(count: 0, channels: []) }
        if useOutputEndpoints { return ProxyStatusResponse(count: 0, channels: []) }
        guard let url = URL(string: "\(baseURL)/proxy/ts/status") else {
            throw PVRClientError.invalidResponse
        }
        return try await authenticatedRequest(url)
    }

    // MARK: - M3U Accounts

    func getM3UAccounts() async throws -> [M3UAccount] {
        guard !config.isDemoMode else { return [] }
        if useOutputEndpoints { return [] }
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
        let (data, response) = try await loggedData(from: url)
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
        let (data, response) = try await loggedData(from: url)
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
                let (catData, catResponse) = try await loggedData(from: catURL)
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
        let (data, response) = try await loggedData(from: url)
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
    private var currentEpisodeNum = ""
    private var currentEpisodeNumSystem = ""
    private var parsedSeason: Int?
    private var parsedEpisode: Int?
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
            currentEpisodeNum = ""
            currentEpisodeNumSystem = ""
            parsedSeason = nil
            parsedEpisode = nil
        }

        if elementName == "episode-num" {
            currentEpisodeNumSystem = attributeDict["system"] ?? ""
            currentEpisodeNum = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inProgramme else { return }
        switch currentElement {
        case "title": currentTitle += string
        case "sub-title": currentSubTitle += string
        case "desc": currentDesc += string
        case "category": currentCategory += string
        case "episode-num": currentEpisodeNum += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "episode-num" && inProgramme {
            let num = currentEpisodeNum.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentEpisodeNumSystem == "xmltv_ns" {
                // Format: "season.episode.part" (0-indexed)
                let parts = num.split(separator: ".")
                if parts.count >= 2,
                   let s = Int(parts[0]), let e = Int(parts[1]) {
                    parsedSeason = s + 1  // Convert from 0-indexed
                    parsedEpisode = e + 1
                }
            } else if currentEpisodeNumSystem == "onscreen" {
                // Format: "S01E05" or similar
                if let info = SeriesInfo.parse(name: num) {
                    parsedSeason = info.season
                    parsedEpisode = info.episode
                }
            }
            currentElement = ""
            return
        }

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
                channelId: channelId,
                season: parsedSeason,
                episode: parsedEpisode
            )

            programs[channelId, default: []].append(program)
        }

        if elementName != "programme" && elementName != "episode-num" {
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

private nonisolated struct DispatcharrAPIErrorResponse: Decodable {
    let detail: String?
    let message: String?
    let error: String?
    let nonFieldErrors: [String]?
    let errors: [String: [String]]?

    enum CodingKeys: String, CodingKey {
        case detail, message, error, errors
        case nonFieldErrors = "non_field_errors"
    }

    var bestMessage: String? {
        if let detail, !detail.isEmpty { return detail }
        if let message, !message.isEmpty { return message }
        if let error, !error.isEmpty { return error }
        if let first = nonFieldErrors?.first, !first.isEmpty { return first }
        if let firstError = errors?.values.first?.first, !firstError.isEmpty { return firstError }
        return nil
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

// Dispatcharr API models extracted to individual files:
// DispatcharrProgram.swift, DispatcharrRecording.swift, DispatcharrCustomProperties.swift,
// DispatcharrProgramRef.swift, M3UAccount.swift, ProxyStatusResponse.swift,
// DispatcharrChannel.swift, DispatcharrListResponse.swift, DispatcharrCodingHelpers.swift



// MARK: - Recording Request Model

private nonisolated struct DispatcharrRecordingRequest: Encodable {
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

private nonisolated struct DispatcharrSeriesRuleRequest: Encodable {
    let mode: String
    let title: String
    let tvgId: String

    enum CodingKeys: String, CodingKey {
        case mode
        case title
        case tvgId = "tvg_id"
    }
}

private nonisolated struct DispatcharrSeriesRulesResponse: Decodable {
    let success: Bool?
    let rules: [DispatcharrSeriesRuleResponseItem]?
}

private nonisolated struct DispatcharrSeriesRuleResponseItem: Decodable {
    let mode: String?
    let title: String?
    let tvgId: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case title
        case tvgId = "tvg_id"
    }
}

private nonisolated struct DispatcharrSeriesRulesEvaluateRequest: Encodable {
    let tvgId: String

    enum CodingKeys: String, CodingKey {
        case tvgId = "tvg_id"
    }
}

private nonisolated struct DispatcharrSeriesRulesEvaluateResponse: Decodable {
    let success: Bool?
    let scheduled: Int?
    let details: [DispatcharrSeriesRulesEvaluateDetail]?
}

private nonisolated struct DispatcharrSeriesRulesEvaluateDetail: Decodable {
    let tvgId: String?
    let title: String?
    let status: String?
    let created: Int?

    enum CodingKeys: String, CodingKey {
        case tvgId = "tvg_id"
        case title
        case status
        case created
    }
}
