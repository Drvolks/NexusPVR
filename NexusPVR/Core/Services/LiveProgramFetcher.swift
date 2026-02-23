//
//  LiveProgramFetcher.swift
//  PVR Client
//
//  Lightweight EPG fetcher for Top Shelf extension.
//  Fetches currently airing programs by keyword match or channel IDs.
//

import Foundation
import CryptoKit

struct TopShelfProgram {
    let programName: String
    let channelId: Int
    let channelName: String
    let startTime: Int
    let endTime: Int
    let desc: String?
    let genres: [String]?

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startTime)) }
    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(endTime)) }
}

enum LiveProgramFetcher {

    /// Fetch currently airing programs that match any of the given keywords.
    static func fetchCurrentByKeywords(
        config: ServerConfig,
        keywords: [String],
        excludeChannelIds: Set<Int> = [],
        limit: Int = 4
    ) async -> [TopShelfProgram] {
        guard config.isConfigured, !config.isDemoMode, !keywords.isEmpty else { return [] }

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        do {
            #if DISPATCHERPVR
            return try await fetchDispatcharrByKeywords(config: config, session: session, keywords: keywords, excludeChannelIds: excludeChannelIds, limit: limit)
            #else
            return try await fetchNextPVRByKeywords(config: config, session: session, keywords: keywords, excludeChannelIds: excludeChannelIds, limit: limit)
            #endif
        } catch {
            return []
        }
    }

    /// Fetch currently airing programs for specific channel IDs.
    static func fetchCurrentForChannels(
        config: ServerConfig,
        channelIds: [Int],
        excludeChannelIds: Set<Int> = [],
        limit: Int = 4
    ) async -> [TopShelfProgram] {
        guard config.isConfigured, !config.isDemoMode, !channelIds.isEmpty else { return [] }

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        do {
            #if DISPATCHERPVR
            return try await fetchDispatcharrForChannels(config: config, session: session, channelIds: channelIds, excludeChannelIds: excludeChannelIds, limit: limit)
            #else
            return try await fetchNextPVRForChannels(config: config, session: session, channelIds: channelIds, excludeChannelIds: excludeChannelIds, limit: limit)
            #endif
        } catch {
            return []
        }
    }

    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }

    // MARK: - NextPVR

    #if !DISPATCHERPVR

    private static func authenticateNextPVR(config: ServerConfig, session: URLSession) async throws -> String {
        let baseURL = config.baseURL
        guard let initiateURL = URL(string: "\(baseURL)/services/service?method=session.initiate&ver=1.0&device=TopShelf&format=json") else {
            throw URLError(.badURL)
        }
        let (initiateData, _) = try await session.data(from: initiateURL)
        let initiateResponse = try JSONDecoder().decode(SessionInitiateResponse.self, from: initiateData)

        guard let sid = initiateResponse.sid, let salt = initiateResponse.salt else {
            throw URLError(.userAuthenticationRequired)
        }

        let pinHash = md5(config.pin)
        let loginHash = md5(":\(pinHash):\(salt)")

        guard let loginURL = URL(string: "\(baseURL)/services/service?method=session.login&sid=\(sid)&md5=\(loginHash)&format=json") else {
            throw URLError(.badURL)
        }
        let (loginData, _) = try await session.data(from: loginURL)
        let loginResponse = try JSONDecoder().decode(SessionLoginResponse.self, from: loginData)
        guard loginResponse.isSuccess else { throw URLError(.userAuthenticationRequired) }
        return sid
    }

    private static func fetchNextPVRChannels(baseURL: String, sid: String, session: URLSession) async throws -> [Channel] {
        var components = URLComponents(string: "\(baseURL)/services/service")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "channel.list"),
            URLQueryItem(name: "sid", value: sid),
            URLQueryItem(name: "format", value: "json")
        ]
        let (data, _) = try await session.data(from: components.url!)
        let response = try JSONDecoder().decode(ChannelListResponse.self, from: data)
        return response.channels ?? []
    }

    private static func fetchNextPVRListings(baseURL: String, sid: String, channelId: Int, session: URLSession) async throws -> [Program] {
        var components = URLComponents(string: "\(baseURL)/services/service")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "channel.listings"),
            URLQueryItem(name: "channel_id", value: String(channelId)),
            URLQueryItem(name: "sid", value: sid),
            URLQueryItem(name: "format", value: "json")
        ]
        let (data, _) = try await session.data(from: components.url!)
        let response = try JSONDecoder().decode(ProgramListingsResponse.self, from: data)
        return response.listings ?? []
    }

    private static func fetchNextPVRByKeywords(
        config: ServerConfig, session: URLSession,
        keywords: [String], excludeChannelIds: Set<Int>, limit: Int
    ) async throws -> [TopShelfProgram] {
        let sid = try await authenticateNextPVR(config: config, session: session)
        let channels = try await fetchNextPVRChannels(baseURL: config.baseURL, sid: sid, session: session)
        let channelMap = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0.name) })
        let lowercaseKeywords = keywords.map { $0.lowercased() }
        let now = Date()
        var results: [TopShelfProgram] = []

        // Fetch listings for channels (limit to 30 to stay in time budget)
        for channel in channels.prefix(30) {
            if excludeChannelIds.contains(channel.id) { continue }
            guard let listings = try? await fetchNextPVRListings(baseURL: config.baseURL, sid: sid, channelId: channel.id, session: session) else { continue }

            for program in listings where program.startDate <= now && program.endDate > now {
                let searchText = [program.name, program.subtitle ?? "", program.desc ?? ""].joined(separator: " ").lowercased()
                if lowercaseKeywords.contains(where: { searchText.contains($0) }) {
                    results.append(TopShelfProgram(
                        programName: program.name, channelId: channel.id,
                        channelName: channelMap[channel.id] ?? channel.name,
                        startTime: program.start, endTime: program.end,
                        desc: program.desc, genres: program.genres
                    ))
                    if results.count >= limit { return results }
                    break // One program per channel
                }
            }
        }
        return results
    }

    private static func fetchNextPVRForChannels(
        config: ServerConfig, session: URLSession,
        channelIds: [Int], excludeChannelIds: Set<Int>, limit: Int
    ) async throws -> [TopShelfProgram] {
        let sid = try await authenticateNextPVR(config: config, session: session)
        let channels = try await fetchNextPVRChannels(baseURL: config.baseURL, sid: sid, session: session)
        let channelMap = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0.name) })
        let now = Date()
        var results: [TopShelfProgram] = []

        for channelId in channelIds {
            if excludeChannelIds.contains(channelId) { continue }
            guard let listings = try? await fetchNextPVRListings(baseURL: config.baseURL, sid: sid, channelId: channelId, session: session) else { continue }

            if let program = listings.first(where: { $0.startDate <= now && $0.endDate > now }) {
                results.append(TopShelfProgram(
                    programName: program.name, channelId: channelId,
                    channelName: channelMap[channelId] ?? "Channel \(channelId)",
                    startTime: program.start, endTime: program.end,
                    desc: program.desc, genres: program.genres
                ))
                if results.count >= limit { return results }
            }
        }
        return results
    }

    private static func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    #endif

    // MARK: - Dispatcharr

    #if DISPATCHERPVR

    private static func authenticateDispatcharr(config: ServerConfig, session: URLSession) async throws -> String {
        guard let tokenURL = URL(string: "\(config.baseURL)/api/accounts/token/") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": config.username, "password": config.password])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        struct TokenResponse: Decodable { let access: String }
        return try JSONDecoder().decode(TokenResponse.self, from: data).access
    }

    private nonisolated struct SimpleChannel: Decodable {
        let id: Int
        let name: String
        let tvgId: String?
        let epgDataId: Int?

        enum CodingKeys: String, CodingKey {
            case id, name
            case tvgId = "tvg_id"
            case epgDataId = "epg_data_id"
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
            name = try container.decode(String.self, forKey: .name)
            tvgId = try container.decodeIfPresent(String.self, forKey: .tvgId)
            epgDataId = try container.decodeIfPresent(Int.self, forKey: .epgDataId)
        }
    }

    private nonisolated struct SimpleEPGData: Decodable {
        let tvgId: String?
        enum CodingKeys: String, CodingKey { case tvgId = "tvg_id" }
    }

    private nonisolated struct SimpleProgram: Decodable {
        let id: Int
        let title: String
        let subTitle: String?
        let description: String?
        let start: String
        let end: String
        let tvgId: String?
        let channel: Int?

        enum CodingKeys: String, CodingKey {
            case id, title, description
            case subTitle = "sub_title"
            case startTime = "start_time"
            case endTime = "end_time"
            case start, end
            case tvgId = "tvg_id"
            case channel
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
            title = try container.decode(String.self, forKey: .title)
            subTitle = try container.decodeIfPresent(String.self, forKey: .subTitle)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            // Dispatcharr uses start_time/end_time, NextPVR uses start/end
            start = try container.decodeIfPresent(String.self, forKey: .startTime)
                ?? (try container.decode(String.self, forKey: .start))
            end = try container.decodeIfPresent(String.self, forKey: .endTime)
                ?? (try container.decode(String.self, forKey: .end))
            tvgId = try container.decodeIfPresent(String.self, forKey: .tvgId)
            if let intCh = try? container.decode(Int.self, forKey: .channel) {
                channel = intCh
            } else if let stringCh = try? container.decode(String.self, forKey: .channel), let parsed = Int(stringCh) {
                channel = parsed
            } else {
                channel = nil
            }
        }
    }

    private nonisolated struct PaginatedResponse<T: Decodable>: Decodable {
        let results: [T]?
        let data: [T]?
        let next: String?
        private let directItems: [T]?

        var items: [T] { results ?? data ?? directItems ?? [] }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                results = try container.decodeIfPresent([T].self, forKey: .results)
                data = try container.decodeIfPresent([T].self, forKey: .data)
                next = try container.decodeIfPresent(String.self, forKey: .next)
                directItems = nil
            } else {
                let singleValue = try decoder.singleValueContainer()
                directItems = try singleValue.decode([T].self)
                results = nil
                data = nil
                next = nil
            }
        }

        enum CodingKeys: String, CodingKey { case results, data, next }
    }

    private static func fetchDispatcharrChannelsAndPrograms(
        config: ServerConfig, session: URLSession, token: String
    ) async throws -> (channels: [SimpleChannel], programs: [SimpleProgram], tvgIdMap: [String: Int]) {
        // Fetch channels and EPG in parallel
        async let channelsTask: [SimpleChannel] = {
            guard let url = URL(string: "\(config.baseURL)/api/channels/channels/?page_size=10000") else { return [] }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder().decode(PaginatedResponse<SimpleChannel>.self, from: data)
            return response.items
        }()

        async let programsTask: [SimpleProgram] = {
            guard let url = URL(string: "\(config.baseURL)/api/epg/grid/?page_size=50000") else { return [] }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder().decode(PaginatedResponse<SimpleProgram>.self, from: data)
            return response.items
        }()

        let channels = try await channelsTask
        let programs = try await programsTask

        // Build tvg_id → channelId map (from channel's own tvg_id)
        var tvgIdMap: [String: Int] = [:]
        for ch in channels {
            if let tvgId = ch.tvgId, !tvgId.isEmpty {
                tvgIdMap[tvgId] = ch.id
            }
        }

        // Resolve EPG data tvg_ids for channels that have an epgDataId
        // (the EPG source's tvg_id may differ from the channel's tvg_id)
        let channelsNeedingResolve = channels.filter { $0.epgDataId != nil }
        if !channelsNeedingResolve.isEmpty {
            await withTaskGroup(of: (Int, String?).self) { group in
                for ch in channelsNeedingResolve {
                    guard let epgDataId = ch.epgDataId else { continue }
                    let channelId = ch.id
                    group.addTask {
                        guard let url = URL(string: "\(config.baseURL)/api/epg/epgdata/\(epgDataId)/") else {
                            return (channelId, nil)
                        }
                        var request = URLRequest(url: url)
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        guard let (data, _) = try? await session.data(for: request),
                              let epgData = try? JSONDecoder().decode(SimpleEPGData.self, from: data) else {
                            return (channelId, nil)
                        }
                        return (channelId, epgData.tvgId)
                    }
                }
                for await (channelId, epgTvgId) in group {
                    if let epgTvgId, !epgTvgId.isEmpty, tvgIdMap[epgTvgId] == nil {
                        tvgIdMap[epgTvgId] = channelId
                    }
                }
            }
        }

        return (channels, programs, tvgIdMap)
    }

    private static func resolveChannelId(
        program: SimpleProgram,
        tvgIdToChannelId: [String: Int]
    ) -> Int? {
        if let directId = program.channel { return directId }
        if let tvgId = program.tvgId, let mapped = tvgIdToChannelId[tvgId] { return mapped }
        return nil
    }

    private static func fetchDispatcharrByKeywords(
        config: ServerConfig, session: URLSession,
        keywords: [String], excludeChannelIds: Set<Int>, limit: Int
    ) async throws -> [TopShelfProgram] {
        let token = try await authenticateDispatcharr(config: config, session: session)
        let (channels, programs, tvgIdToChannelId) = try await fetchDispatcharrChannelsAndPrograms(config: config, session: session, token: token)

        let channelMap = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0.name) })

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        let now = Date()
        let lowercaseKeywords = keywords.map { $0.lowercased() }
        var results: [TopShelfProgram] = []
        var seenChannels: Set<Int> = []

        for program in programs {
            guard let channelId = resolveChannelId(program: program, tvgIdToChannelId: tvgIdToChannelId) else { continue }
            if excludeChannelIds.contains(channelId) || seenChannels.contains(channelId) { continue }

            let startDate = formatter.date(from: program.start) ?? fallbackFormatter.date(from: program.start) ?? Date.distantPast
            let endDate = formatter.date(from: program.end) ?? fallbackFormatter.date(from: program.end) ?? Date.distantPast
            guard startDate <= now && endDate > now else { continue }

            let searchText = [program.title, program.subTitle ?? "", program.description ?? ""].joined(separator: " ").lowercased()
            if lowercaseKeywords.contains(where: { searchText.contains($0) }) {
                seenChannels.insert(channelId)
                results.append(TopShelfProgram(
                    programName: program.title, channelId: channelId,
                    channelName: channelMap[channelId] ?? "Channel \(channelId)",
                    startTime: Int(startDate.timeIntervalSince1970),
                    endTime: Int(endDate.timeIntervalSince1970),
                    desc: program.description, genres: nil
                ))
                if results.count >= limit { return results }
            }
        }
        return results
    }

    private static func fetchDispatcharrForChannels(
        config: ServerConfig, session: URLSession,
        channelIds: [Int], excludeChannelIds: Set<Int>, limit: Int
    ) async throws -> [TopShelfProgram] {
        let token = try await authenticateDispatcharr(config: config, session: session)
        let (channels, programs, tvgIdToChannelId) = try await fetchDispatcharrChannelsAndPrograms(config: config, session: session, token: token)

        let channelMap = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0.name) })

        let targetSet = Set(channelIds).subtracting(excludeChannelIds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        let now = Date()
        var results: [TopShelfProgram] = []
        var seenChannels: Set<Int> = []

        for program in programs {
            guard let channelId = resolveChannelId(program: program, tvgIdToChannelId: tvgIdToChannelId) else { continue }
            guard targetSet.contains(channelId), !seenChannels.contains(channelId) else { continue }

            let startDate = formatter.date(from: program.start) ?? fallbackFormatter.date(from: program.start) ?? Date.distantPast
            let endDate = formatter.date(from: program.end) ?? fallbackFormatter.date(from: program.end) ?? Date.distantPast
            guard startDate <= now && endDate > now else { continue }

            seenChannels.insert(channelId)
            results.append(TopShelfProgram(
                programName: program.title, channelId: channelId,
                channelName: channelMap[channelId] ?? "Channel \(channelId)",
                startTime: Int(startDate.timeIntervalSince1970),
                endTime: Int(endDate.timeIntervalSince1970),
                desc: program.description, genres: nil
            ))
            if results.count >= limit { return results }
        }
        return results
    }

    #endif
}
