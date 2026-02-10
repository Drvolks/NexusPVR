//
//  TopicsView.swift
//  nextpvr-apple-client
//
//  Shows upcoming programs matching user's topic keywords
//

import SwiftUI

struct TopicsView: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = TopicsViewModel()
    @State private var selectedProgramDetail: (program: Program, channel: Channel)?
    @State private var selectedKeyword: String = ""
    @State private var refreshTrigger = UUID()

    private var filteredPrograms: [MatchingProgram] {
        guard !selectedKeyword.isEmpty else { return viewModel.matchingPrograms }
        return viewModel.matchingPrograms.filter { $0.matchedKeyword == selectedKeyword }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Keyword tabs
                if !viewModel.keywords.isEmpty {
                    Picker("Topic", selection: $selectedKeyword) {
                        ForEach(viewModel.keywords, id: \.self) { keyword in
                            Text(keyword).tag(keyword)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.surface)
                }

                // Content
                Group {
                    if viewModel.keywords.isEmpty {
                        emptyKeywordsView
                    } else if viewModel.isLoading && viewModel.matchingPrograms.isEmpty {
                        loadingView
                    } else if let error = viewModel.error {
                        errorView(error)
                    } else if filteredPrograms.isEmpty {
                        noMatchesView
                    } else {
                        programsList
                    }
                }
            }
            .sheet(item: Binding(
                get: { selectedProgramDetail.map { ProgramTopicDetail(program: $0.program, channel: $0.channel) } },
                set: { selectedProgramDetail = $0.map { ($0.program, $0.channel) } }
            ), onDismiss: {
                // Refresh all rows to update recording status
                refreshTrigger = UUID()
            }) { detail in
                ProgramDetailView(program: detail.program, channel: detail.channel)
                    .environmentObject(client)
                    .environmentObject(appState)
            }
            .onChange(of: viewModel.keywords) {
                if selectedKeyword.isEmpty, let first = viewModel.keywords.first {
                    selectedKeyword = first
                }
            }
        }
        .background(Theme.background)
        .task {
            await viewModel.loadData(using: client)
        }
    }

    private var emptyKeywordsView: some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "star.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No Topics Configured")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Add keywords in Settings to see matching programs")
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
            Text("Finding matching programs...")
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

    private var noMatchesView: some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No Matching Programs")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("No upcoming programs match: \(selectedKeyword.isEmpty ? viewModel.keywords.joined(separator: ", ") : selectedKeyword)")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var programsList: some View {
        #if os(tvOS)
        ScrollView {
            LazyVStack(spacing: Theme.spacingMD) {
                ForEach(filteredPrograms) { item in
                    TopicProgramRowTV(
                        program: item.program,
                        channel: item.channel,
                        matchedKeyword: item.matchedKeyword,
                        onRecordingChanged: {
                            refreshTrigger = UUID()
                        },
                        onShowDetails: {
                            selectedProgramDetail = (program: item.program, channel: item.channel)
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
            ForEach(filteredPrograms) { item in
                TopicProgramRow(
                    program: item.program,
                    channel: item.channel,
                    matchedKeyword: item.matchedKeyword,
                    onRecordingChanged: {
                        refreshTrigger = UUID()
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedProgramDetail = (program: item.program, channel: item.channel)
                }
                .listRowBackground(Theme.surface)
                .id("\(item.id)-\(refreshTrigger)")
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.loadData(using: client)
        }
        #endif
    }
}

// Helper struct for sheet binding
private struct ProgramTopicDetail: Identifiable {
    let id = UUID()
    let program: Program
    let channel: Channel
}

#Preview {
    TopicsView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
