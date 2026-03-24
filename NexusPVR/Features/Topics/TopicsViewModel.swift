//
//  TopicsViewModel.swift
//  nextpvr-apple-client
//
//  View model for topics/keywords matching
//

import SwiftUI
import Combine

nonisolated struct MatchingProgram: Identifiable, Sendable {
    var id: String { "\(program.id)-\(channel.id)" }
    let program: Program
    let channel: Channel
    let matchedKeyword: String

    static let scheduledKeyword = "Scheduled"
}

@MainActor
final class TopicsViewModel: ObservableObject {
    @Published var matchingPrograms: [MatchingProgram] = []
    @Published var keywords: [String] = []
    @Published var isLoading = false
    @Published var error: String?

    weak var epgCache: EPGCache?
    var client: PVRClient?
    private var syncObserver: NSObjectProtocol?

    init() {
        // Observe iCloud sync changes and reload keywords
        syncObserver = NotificationCenter.default.addObserver(
            forName: .preferencesDidSync,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let prefs = UserPreferences.load()
            Task { @MainActor [weak self] in
                self?.keywords = prefs.keywords
            }
        }
    }

    deinit {
        if let observer = syncObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadData() async {
        let prefs = UserPreferences.load()
        keywords = prefs.keywords

        guard let cache = epgCache, cache.hasLoaded else {
            print("[Topics] loadData: epgCache=\(epgCache == nil ? "nil" : "set") hasLoaded=\(epgCache?.hasLoaded ?? false) client=\(client == nil ? "nil" : "set")")
            return
        }
        print("[Topics] loadData: starting with \(keywords.count) keywords, client=\(client == nil ? "nil" : "set")")

        isLoading = true
        error = nil

        // Load keyword matches
        var matches: [MatchingProgram] = []
        if !keywords.isEmpty {
            matches = await cache.matchingPrograms(keywords: keywords)
        }

        // Load scheduled recordings and convert to MatchingProgram
        if let client {
            let scheduledMatches = await loadScheduledAsTopics(cache: cache)
            matches.append(contentsOf: scheduledMatches)
            matches.sort { $0.program.startDate < $1.program.startDate }
        }

        matchingPrograms = matches
        isLoading = false
    }

    private func loadScheduledAsTopics(cache: EPGCache) async -> [MatchingProgram] {
        guard let client else { return [] }
        do {
            let (_, recording, scheduled) = try await client.getAllRecordings()
            let allScheduled = recording + scheduled
            let channelMap = cache.channelMap

            return allScheduled.compactMap { rec -> MatchingProgram? in
                guard let channelId = rec.channelId,
                      let channel = channelMap[channelId],
                      let startTime = rec.startTime,
                      let duration = rec.duration else { return nil }

                let program = Program(
                    id: rec.epgEventId ?? rec.id,
                    name: rec.name,
                    subtitle: rec.subtitle,
                    desc: rec.desc,
                    start: startTime,
                    end: startTime + duration,
                    genres: rec.genres,
                    channelId: channelId,
                    season: rec.season,
                    episode: rec.episode
                )

                return MatchingProgram(
                    program: program,
                    channel: channel,
                    matchedKeyword: MatchingProgram.scheduledKeyword
                )
            }
        } catch {
            return []
        }
    }
}
