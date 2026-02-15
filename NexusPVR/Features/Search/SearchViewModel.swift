//
//  SearchViewModel.swift
//  NexusPVR
//
//  View model for EPG search
//

import SwiftUI
import Combine

struct SearchResult: Identifiable {
    var id: String { "\(program.id)-\(channel.id)" }
    let program: Program
    let channel: Channel
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [SearchResult] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var hasSearched = false

    private var channels: [Channel] = []
    private var listings: [Int: [Program]] = [:]
    private var dataLoaded = false
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // On tvOS, search is triggered explicitly on submit
        #if !os(tvOS)
        // Debounce search text changes by 300ms
        $searchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.search()
            }
            .store(in: &cancellables)
        #endif
    }

    func loadData(using client: PVRClient) async {
        guard client.isConfigured else {
            error = "Server not configured"
            return
        }

        do {
            if !client.isAuthenticated {
                try await client.authenticate()
            }

            channels = try await client.getChannels()
            listings = try await client.getAllListings(for: channels)
            dataLoaded = true

            // If there's already a search query, run the search
            if searchText.count >= 2 {
                search()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func search() {
        guard searchText.count >= 2 else {
            results = []
            hasSearched = false
            return
        }

        guard dataLoaded else { return }

        hasSearched = true

        // Cancel any in-flight search
        searchTask?.cancel()

        let query = searchText.lowercased()
        let channels = self.channels
        let listings = self.listings

        searchTask = Task.detached(priority: .userInitiated) {
            var matches: [SearchResult] = []

            for channel in channels {
                guard !Task.isCancelled else { return }
                guard let programs = listings[channel.id] else { continue }

                for program in programs {
                    let text = [
                        program.name,
                        program.subtitle ?? "",
                        program.desc ?? ""
                    ].joined(separator: " ").lowercased()

                    if text.contains(query) {
                        matches.append(SearchResult(program: program, channel: channel))
                    }
                }
            }

            guard !Task.isCancelled else { return }

            // Sort: upcoming first (by start date), then past
            let now = Date()
            let sorted = matches.sorted { a, b in
                let aUpcoming = a.program.endDate > now
                let bUpcoming = b.program.endDate > now
                if aUpcoming != bUpcoming {
                    return aUpcoming
                }
                return a.program.startDate < b.program.startDate
            }

            await MainActor.run {
                self.results = sorted
            }
        }
    }
}
