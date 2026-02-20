//
//  RecordingFetcher.swift
//  PVR Client
//
//  Lightweight recording fetcher for use by Top Shelf extension.
//  Not @MainActor — safe to run in extension process.
//

import Foundation
import CryptoKit

enum RecordingFetcher {

    static func fetchRecentRecordings(config: ServerConfig, limit: Int = 5) async -> [Recording] {
        guard config.isConfigured, !config.isDemoMode else { return [] }

        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 15
            c.timeoutIntervalForResource = 15
            return c
        }())

        defer { session.invalidateAndCancel() }

        do {
            #if DISPATCHERPVR
            return try await fetchDispatcharr(config: config, session: session, limit: limit)
            #else
            return try await fetchNextPVR(config: config, session: session, limit: limit)
            #endif
        } catch {
            return []
        }
    }

    // MARK: - NextPVR

    #if !DISPATCHERPVR
    private static func fetchNextPVR(config: ServerConfig, session: URLSession, limit: Int) async throws -> [Recording] {
        let baseURL = config.baseURL

        // Step 1: Initiate session
        guard let initiateURL = URL(string: "\(baseURL)/services/service?method=session.initiate&ver=1.0&device=TopShelf&format=json") else {
            return []
        }
        let (initiateData, _) = try await session.data(from: initiateURL)
        let initiateResponse = try JSONDecoder().decode(SessionInitiateResponse.self, from: initiateData)

        guard let sid = initiateResponse.sid, let salt = initiateResponse.salt else {
            return []
        }

        // Step 2: Login with MD5 hash
        let pinHash = md5(config.pin)
        let loginHash = md5(":\(pinHash):\(salt)")

        guard let loginURL = URL(string: "\(baseURL)/services/service?method=session.login&sid=\(sid)&md5=\(loginHash)&format=json") else {
            return []
        }
        let (loginData, _) = try await session.data(from: loginURL)
        let loginResponse = try JSONDecoder().decode(SessionLoginResponse.self, from: loginData)

        guard loginResponse.isSuccess else { return [] }

        // Step 3: Fetch completed recordings
        var components = URLComponents(string: "\(baseURL)/services/service")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "recording.list"),
            URLQueryItem(name: "sid", value: sid),
            URLQueryItem(name: "filter", value: "ready"),
            URLQueryItem(name: "format", value: "json")
        ]

        guard let recordingsURL = components.url else { return [] }
        let (data, _) = try await session.data(from: recordingsURL)
        let response = try JSONDecoder().decode(RecordingListResponse.self, from: data)

        let recordings = response.recordings ?? []
        return Array(
            recordings
                .sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
                .prefix(limit)
        )
    }

    private static func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    #endif

    // MARK: - Dispatcharr

    #if DISPATCHERPVR
    private static func fetchDispatcharr(config: ServerConfig, session: URLSession, limit: Int) async throws -> [Recording] {
        let baseURL = config.baseURL

        // Step 1: Authenticate with JWT
        guard let tokenURL = URL(string: "\(baseURL)/api/accounts/token/") else { return [] }

        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = try JSONEncoder().encode([
            "username": config.username,
            "password": config.password
        ])

        let (tokenData, tokenResponse) = try await session.data(for: tokenRequest)
        guard let httpResponse = tokenResponse as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        struct TokenResponse: Decodable {
            let access: String
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: tokenData)

        // Step 2: Fetch recordings
        guard let recordingsURL = URL(string: "\(baseURL)/api/channels/recordings/") else { return [] }

        var recordingsRequest = URLRequest(url: recordingsURL)
        recordingsRequest.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: recordingsRequest)

        struct DispatcharrRec: Decodable {
            let id: Int
            let startTime: String
            let endTime: String
            let channel: Int
            let customProperties: CustomProps?

            enum CodingKeys: String, CodingKey {
                case id
                case startTime = "start_time"
                case endTime = "end_time"
                case channel
                case customProperties = "custom_properties"
            }

            struct CustomProps: Decodable {
                let program: ProgramInfo?
                struct ProgramInfo: Decodable {
                    let title: String?
                    let subTitle: String?
                    let description: String?
                    let id: Int?
                    enum CodingKeys: String, CodingKey {
                        case title, subTitle = "sub_title", description, id
                    }
                }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let intId = try? container.decode(Int.self, forKey: .id) {
                    id = intId
                } else if let stringId = try? container.decode(String.self, forKey: .id), let parsed = Int(stringId) {
                    id = parsed
                } else {
                    id = 0
                }
                startTime = try container.decode(String.self, forKey: .startTime)
                endTime = try container.decode(String.self, forKey: .endTime)
                customProperties = try container.decodeIfPresent(CustomProps.self, forKey: .customProperties)
                if let intCh = try? container.decode(Int.self, forKey: .channel) {
                    channel = intCh
                } else if let stringCh = try? container.decode(String.self, forKey: .channel), let parsed = Int(stringCh) {
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

                let now = Date()
                let status: String
                if endDate < now { status = "ready" }
                else if startDate <= now && endDate > now { status = "recording" }
                else { status = "pending" }

                return Recording(
                    id: id, name: name, subtitle: subtitle, desc: desc,
                    startTime: Int(startDate.timeIntervalSince1970),
                    duration: duration, channel: nil, channelId: channel,
                    status: status
                )
            }
        }

        struct ListResponse: Decodable {
            let results: [DispatcharrRec]?
            let data: [DispatcharrRec]?
            private let directItems: [DispatcharrRec]?

            var allItems: [DispatcharrRec] {
                results ?? data ?? directItems ?? []
            }

            init(from decoder: Decoder) throws {
                if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                    results = try container.decodeIfPresent([DispatcharrRec].self, forKey: .results)
                    data = try container.decodeIfPresent([DispatcharrRec].self, forKey: .data)
                    directItems = nil
                } else {
                    let singleValueContainer = try decoder.singleValueContainer()
                    directItems = try singleValueContainer.decode([DispatcharrRec].self)
                    results = nil
                    data = nil
                }
            }

            enum CodingKeys: String, CodingKey {
                case results, data
            }
        }

        let listResponse = try JSONDecoder().decode(ListResponse.self, from: data)
        let recordings = listResponse.allItems.map { $0.toRecording() }

        return Array(
            recordings
                .filter { $0.recordingStatus == .ready }
                .sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
                .prefix(limit)
        )
    }
    #endif
}
