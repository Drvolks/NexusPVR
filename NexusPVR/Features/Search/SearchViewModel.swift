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

    weak var epgCache: EPGCache?
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

    func search() {
        guard searchText.count >= 2 else {
            results = []
            hasSearched = false
            return
        }

        guard let cache = epgCache, cache.hasLoaded else { return }

        hasSearched = true

        searchTask?.cancel()

        let query = searchText
        searchTask = Task {
            let matches = await cache.searchPrograms(query: query)
            if !Task.isCancelled {
                results = matches
            }
        }
    }
}
