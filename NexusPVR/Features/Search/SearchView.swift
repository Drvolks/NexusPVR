//
//  SearchView.swift
//  NexusPVR
//
//  Search EPG programs by title/description
//

import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var epgCache: EPGCache
    @StateObject private var viewModel = SearchViewModel()
    @State private var selectedProgramDetail: ProgramSearchDetail?
    @State private var refreshTrigger = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if !epgCache.hasLoaded {
                    loadingView
                } else if let error = viewModel.error {
                    errorView(error)
                } else if !viewModel.hasSearched {
                    emptyStateView
                } else if viewModel.results.isEmpty {
                    noResultsView
                } else {
                    resultsList
                }
            }
            #if os(tvOS)
            .safeAreaInset(edge: .top) {
                tvSearchBar
            }
            #else
            .searchable(text: $viewModel.searchText, prompt: "Search programs")
            #endif
            .sheet(item: $selectedProgramDetail) { detail in
                ProgramDetailView(
                    program: detail.program,
                    channel: detail.channel,
                    initialRecordingId: detail.recordingId,
                    initialCompletedRecording: detail.completedRecording,
                    onRecordingChanged: {
                        refreshTrigger = UUID()
                    }
                )
                .environmentObject(client)
                .environmentObject(appState)
            }
        }
        .background(Theme.background)
        .onAppear {
            viewModel.epgCache = epgCache
        }
    }

    #if os(tvOS)
    private var tvSearchBar: some View {
        HStack(spacing: Theme.spacingMD) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search programs", text: $viewModel.searchText)
                .onSubmit {
                    viewModel.search()
                }
        }
        .padding(.horizontal, Theme.spacingXL)
        .padding(.vertical, Theme.spacingMD)
        .background(Theme.surface)
    }
    #endif

    private var emptyStateView: some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("Search EPG Programs")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Search by program title or description")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: Theme.spacingMD) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.accent)
            Text("Loading EPG data...")
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.warning)
            Text("Unable to load programs")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No Matching Programs")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("No programs match \"\(viewModel.searchText)\"")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        #if os(tvOS)
        ScrollView {
            LazyVStack(spacing: Theme.spacingMD) {
                ForEach(viewModel.results) { item in
                    SearchResultRowTV(
                        program: item.program,
                        channel: item.channel,
                        onRecordingChanged: {
                            refreshTrigger = UUID()
                        },
                        onShowDetails: {
                            selectedProgramDetail = ProgramSearchDetail(program: item.program, channel: item.channel)
                        }
                    )
                    .environmentObject(client)
                    .environmentObject(appState)
                    .id("\(item.id)-\(refreshTrigger)")
                }
            }
            .padding()
        }
        #else
        List {
            ForEach(viewModel.results) { item in
                SearchResultRow(
                    program: item.program,
                    channel: item.channel,
                    onRecordingChanged: {
                        refreshTrigger = UUID()
                    },
                    onShowDetails: { recordingId, completedRecording in
                        selectedProgramDetail = ProgramSearchDetail(
                            program: item.program,
                            channel: item.channel,
                            recordingId: recordingId,
                            completedRecording: completedRecording
                        )
                    }
                )
                .contentShape(Rectangle())
                .listRowBackground(Theme.surface)
                .id("\(item.id)-\(refreshTrigger)")
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("search-results")
        #endif
    }
}

private struct ProgramSearchDetail: Identifiable {
    var id: String { "\(program.id)-\(channel.id)" }
    let program: Program
    let channel: Channel
    var recordingId: Int? = nil
    var completedRecording: Recording? = nil
}

#Preview {
    SearchView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .environmentObject(EPGCache())
        .preferredColorScheme(.dark)
}
