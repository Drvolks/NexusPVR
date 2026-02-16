//
//  TopicsViewModel.swift
//  nextpvr-apple-client
//
//  View model for topics/keywords matching
//

import SwiftUI
import Combine

struct MatchingProgram: Identifiable {
    var id: String { "\(program.id)-\(channel.id)" }
    let program: Program
    let channel: Channel
    let matchedKeyword: String
}

@MainActor
final class TopicsViewModel: ObservableObject {
    @Published var matchingPrograms: [MatchingProgram] = []
    @Published var keywords: [String] = []
    @Published var isLoading = false
    @Published var error: String?

    weak var epgCache: EPGCache?
    private var syncObserver: NSObjectProtocol?

    init() {
        // Observe iCloud sync changes and reload keywords
        syncObserver = NotificationCenter.default.addObserver(
            forName: .preferencesDidSync,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let prefs = UserPreferences.load()
            self?.keywords = prefs.keywords
        }
    }

    deinit {
        if let observer = syncObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadData() async {
        await Task.yield()

        let prefs = UserPreferences.load()
        keywords = prefs.keywords

        guard !keywords.isEmpty else {
            matchingPrograms = []
            return
        }

        guard let cache = epgCache, cache.hasLoaded else {
            error = "EPG data not loaded"
            return
        }

        isLoading = true
        error = nil

        let matches = await cache.matchingPrograms(keywords: keywords)
        matchingPrograms = matches
        isLoading = false
    }
}
