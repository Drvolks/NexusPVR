//
//  EPGCache.swift
//  PVR Client
//
//  Central cache/index for channels and EPG data.
//  Loads all data upfront, provides windowed access for the guide,
//  and instant search/topic matching without additional network calls.
//

import SwiftUI
import Combine

@MainActor
final class EPGCache: ObservableObject {
    /// All channels (full list, sorted by number)
    @Published var channels: [Channel] = []
    /// Channels to display in the guide — first 20 initially, all after EPG loads
    @Published var visibleChannels: [Channel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var isFullyLoaded = false
    @Published private(set) var error: String?

    private(set) var channelMap: [Int: Channel] = [:]
    private(set) var epg: [Int: [Program]] = [:]
    private var loadedDays: Set<String> = [] // "yyyy-MM-dd" keys
    private var backgroundLoadTask: Task<Void, Never>?
    private var isLoadInProgress = false

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = Calendar.current.timeZone
        return f
    }()

    // MARK: - Loading

    func loadData(using client: PVRClient) async {
        // Prevent concurrent loads
        guard !isLoadInProgress else { return }
        guard client.isConfigured else {
            error = "Server not configured"
            return
        }

        backgroundLoadTask?.cancel()
        isLoadInProgress = true
        isLoading = true
        error = nil
        let totalStart = CFAbsoluteTimeGetCurrent()

        do {
            if !client.isAuthenticated {
                let authStart = CFAbsoluteTimeGetCurrent()
                try await client.authenticate()
                print("[EPGCache] Auth: \(ms(since: authStart))ms")
            }

            // Fetch all channels
            let channelsStart = CFAbsoluteTimeGetCurrent()
            let loaded = try await client.getChannels()
            let sorted = loaded.sorted { $0.number < $1.number }
            channels = sorted
            channelMap = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            print("[EPGCache] Channels: \(sorted.count) in \(ms(since: channelsStart))ms")

            // Show the grid immediately with all channels
            // LazyVStack only renders visible rows (~15), so 1000 channels is fine
            visibleChannels = sorted
            hasLoaded = true
            isLoading = false
            print("[EPGCache] Grid ready (\(visibleChannels.count) channels): \(ms(since: totalStart))ms")

            // Load EPG in a separate task so loadData() returns immediately
            let channelsForEPG = sorted
            backgroundLoadTask = Task { [weak self] in
                let epgStart = CFAbsoluteTimeGetCurrent()
                do {
                    let listings = try await client.getAllListings(for: channelsForEPG)
                    guard let self, !Task.isCancelled else { return }
                    self.epg = listings
                    // Compute loaded days off main actor
                    let days = await Task.detached(priority: .utility) {
                        var daySet = Set<String>()
                        for programs in listings.values {
                            for program in programs {
                                daySet.insert(Self.dayFormatter.string(from: program.startDate))
                            }
                        }
                        return daySet
                    }.value
                    self.loadedDays = days
                    let programCount = listings.values.reduce(0) { $0 + $1.count }
                    self.isFullyLoaded = true
                    print("[EPGCache] EPG: \(programCount) programs across \(listings.count) channels in \(self.ms(since: epgStart))ms")
                    print("[EPGCache] Total load: \(self.ms(since: totalStart))ms")
                } catch {
                    guard !Task.isCancelled else { return }
                    print("[EPGCache] EPG load failed: \(error.localizedDescription)")
                }
            }

        } catch {
            self.error = error.localizedDescription
            isLoading = false
            isLoadInProgress = false
            hasLoaded = true
            print("[EPGCache] Load failed after \(ms(since: totalStart))ms: \(error.localizedDescription)")
        }
    }

    /// Ensure EPG data for a specific day is loaded
    func ensureDay(_ date: Date, using client: PVRClient) async {
        let key = Self.dayFormatter.string(from: date)
        guard !loadedDays.contains(key) else { return }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let listings = try await client.getAllListings(for: channels)
            var newCount = 0
            for (channelId, programs) in listings {
                var existing = epg[channelId] ?? []
                let existingIds = Set(existing.map(\.id))
                let newPrograms = programs.filter { !existingIds.contains($0.id) }
                newCount += newPrograms.count
                existing.append(contentsOf: newPrograms)
                existing.sort { $0.startDate < $1.startDate }
                epg[channelId] = existing
            }
            markLoadedDays(from: listings)
            print("[EPGCache] Loaded day \(key): \(newCount) new programs in \(ms(since: start))ms")
        } catch {
            // Silently fail — user can retry via date navigation
        }
    }

    /// Prefetch yesterday + tomorrow EPG in background
    func prefetchAdjacentDays(around date: Date, using client: PVRClient) async {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date

        async let _ = ensureDay(yesterday, using: client)
        async let _ = ensureDay(tomorrow, using: client)
    }

    // MARK: - Channel Filtering

    func filteredChannels(matching search: String) -> [Channel] {
        guard !search.isEmpty else { return visibleChannels }
        let query = search.lowercased()
        return visibleChannels.filter { channel in
            channel.name.lowercased().contains(query) ||
            String(channel.number).contains(query)
        }
    }

    // MARK: - Programs Access

    func programs(for channelId: Int, on date: Date) -> [Program] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = dayStart.addingTimeInterval(24 * 3600)

        guard let all = epg[channelId] else { return [] }
        return all.filter { $0.endDate > dayStart && $0.startDate < dayEnd }
    }

    // MARK: - Search

    func searchPrograms(query: String) async -> [SearchResult] {
        let start = CFAbsoluteTimeGetCurrent()
        let q = query.lowercased()
        let epg = self.epg
        let channelMap = self.channelMap

        let results = await Task.detached(priority: .userInitiated) {
            var matches: [SearchResult] = []

            for (channelId, programs) in epg {
                guard !Task.isCancelled else { return [SearchResult]() }
                guard let channel = channelMap[channelId] else { continue }

                for program in programs {
                    let text = [
                        program.name,
                        program.subtitle ?? "",
                        program.desc ?? ""
                    ].joined(separator: " ").lowercased()

                    if text.contains(q) {
                        matches.append(SearchResult(program: program, channel: channel))
                    }
                }
            }

            let now = Date()
            return matches.sorted { a, b in
                let aUpcoming = a.program.endDate > now
                let bUpcoming = b.program.endDate > now
                if aUpcoming != bUpcoming { return aUpcoming }
                return a.program.startDate < b.program.startDate
            }
        }.value
        print("[EPGCache] Search '\(query)': \(results.count) results in \(ms(since: start))ms")
        return results
    }

    func searchProgramsCount(query: String) async -> Int {
        let q = query.lowercased()
        let epg = self.epg

        return await Task.detached(priority: .userInitiated) {
            var count = 0
            for (_, programs) in epg {
                guard !Task.isCancelled else { return 0 }
                for program in programs {
                    let text = [
                        program.name,
                        program.subtitle ?? "",
                        program.desc ?? ""
                    ].joined(separator: " ").lowercased()
                    if text.contains(q) {
                        count += 1
                    }
                }
            }
            return count
        }.value
    }

    // MARK: - Topic Matching

    func matchingPrograms(keywords: [String]) async -> [MatchingProgram] {
        let start = CFAbsoluteTimeGetCurrent()
        let epg = self.epg
        let channelMap = self.channelMap
        let lowercasedKeywords = keywords.map { $0.lowercased() }

        let results = await Task.detached(priority: .userInitiated) {
            var matches: [MatchingProgram] = []
            let now = Date()

            for (channelId, programs) in epg {
                guard !Task.isCancelled else { return [MatchingProgram]() }
                guard let channel = channelMap[channelId] else { continue }

                for program in programs {
                    guard program.endDate > now else { continue }

                    let searchText = [
                        program.name,
                        program.subtitle ?? "",
                        program.desc ?? ""
                    ].joined(separator: " ").lowercased()

                    for (i, keyword) in lowercasedKeywords.enumerated() {
                        if searchText.contains(keyword) {
                            matches.append(MatchingProgram(
                                program: program,
                                channel: channel,
                                matchedKeyword: keywords[i]
                            ))
                            break
                        }
                    }
                }
            }

            return matches.sorted { $0.program.startDate < $1.program.startDate }
        }.value
        print("[EPGCache] Topics (\(keywords.count) keywords): \(results.count) matches in \(ms(since: start))ms")
        return results
    }

    // MARK: - Invalidation

    func invalidate() {
        backgroundLoadTask?.cancel()
        backgroundLoadTask = nil
        channels = []
        visibleChannels = []
        channelMap = [:]
        epg = [:]
        loadedDays = []
        hasLoaded = false
        isFullyLoaded = false
        isLoadInProgress = false
        error = nil
    }

    // MARK: - Private

    private func markLoadedDays(from listings: [Int: [Program]]) {
        for programs in listings.values {
            for program in programs {
                let key = Self.dayFormatter.string(from: program.startDate)
                loadedDays.insert(key)
            }
        }
    }

    private func ms(since start: CFAbsoluteTime) -> String {
        String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}
