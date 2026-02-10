//
//  TopicsViewModel.swift
//  nextpvr-apple-client
//
//  View model for topics/keywords matching
//

import SwiftUI
import Combine

struct MatchingProgram: Identifiable {
    let id = UUID()
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

    func loadData(using client: PVRClient) async {
        await Task.yield()

        // Load keywords from preferences
        let prefs = UserPreferences.load()
        keywords = prefs.keywords

        guard !keywords.isEmpty else {
            matchingPrograms = []
            return
        }

        guard client.isConfigured else {
            error = "Server not configured"
            return
        }

        isLoading = true
        error = nil

        do {
            if !client.isAuthenticated {
                try await client.authenticate()
            }

            // Load channels and their listings
            let channels = try await client.getChannels()
            let listings = try await client.getAllListings(for: channels)

            // Find all programs that match keywords
            var matches: [MatchingProgram] = []
            let now = Date()

            for channel in channels {
                guard let programs = listings[channel.id] else { continue }

                for program in programs {
                    // Only include upcoming programs (not ended)
                    guard program.endDate > now else { continue }

                    // Check if program matches any keyword
                    if let matchedKeyword = matchesKeyword(program: program) {
                        matches.append(MatchingProgram(
                            program: program,
                            channel: channel,
                            matchedKeyword: matchedKeyword
                        ))
                    }
                }
            }

            // Sort by start date
            matchingPrograms = matches.sorted { $0.program.startDate < $1.program.startDate }
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func matchesKeyword(program: Program) -> String? {
        let searchText = [
            program.name,
            program.subtitle ?? "",
            program.desc ?? ""
        ].joined(separator: " ").lowercased()

        for keyword in keywords {
            if searchText.contains(keyword.lowercased()) {
                return keyword
            }
        }

        return nil
    }
}
