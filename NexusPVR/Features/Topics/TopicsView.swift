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
    @State private var selectedProgramDetail: ProgramTopicDetail?
    @State private var selectedKeyword: String = ""
    @State private var refreshTrigger = UUID()
    @State private var showingKeywordsEditor = false
    #if os(tvOS)
    @State private var newKeyword = ""
    @State private var showingAddKeyword = false
    #endif

    private var filteredPrograms: [MatchingProgram] {
        guard !selectedKeyword.isEmpty else { return viewModel.matchingPrograms }
        return viewModel.matchingPrograms.filter { $0.matchedKeyword == selectedKeyword }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Keyword tabs
                if !viewModel.keywords.isEmpty {
                    #if os(tvOS)
                    HStack(spacing: Theme.spacingMD) {
                        ForEach(viewModel.keywords, id: \.self) { keyword in
                            Button {
                                selectedKeyword = keyword
                            } label: {
                                Text(keyword)
                                    .padding(.horizontal, Theme.spacingLG)
                                    .padding(.vertical, Theme.spacingSM)
                                    .background(selectedKeyword == keyword ? Theme.accent : Theme.surfaceElevated)
                                    .foregroundStyle(selectedKeyword == keyword ? .white : Theme.textPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                            }
                            .buttonStyle(.card)
                        }

                        Button {
                            showingAddKeyword = true
                        } label: {
                            Image(systemName: "plus")
                                .padding(Theme.spacingSM)
                                .background(Theme.surfaceElevated)
                                .foregroundStyle(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        }
                        .buttonStyle(.card)

                        if !selectedKeyword.isEmpty {
                            Button {
                                removeKeyword(selectedKeyword)
                            } label: {
                                Image(systemName: "trash")
                                    .padding(Theme.spacingSM)
                                    .background(Theme.surfaceElevated)
                                    .foregroundStyle(Theme.error)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, Theme.spacingXL)
                    .padding(.top, Theme.spacingLG)
                    .padding(.bottom, Theme.spacingSM)
                    #else
                    HStack {
                        Picker("Topic", selection: $selectedKeyword) {
                            ForEach(viewModel.keywords, id: \.self) { keyword in
                                Text(keyword).tag(keyword)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        #if os(macOS)
                        Spacer()
                        Button {
                            showingKeywordsEditor = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        #endif
                    }
                    .padding(.horizontal)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.surface)
                    #endif
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
            .sheet(item: $selectedProgramDetail, onDismiss: {
                // Refresh all rows to update recording status
                refreshTrigger = UUID()
            }) { detail in
                ProgramDetailView(program: detail.program, channel: detail.channel)
                    .environmentObject(client)
                    .environmentObject(appState)
            }
            #if os(tvOS)
            .alert("Add Keyword", isPresented: $showingAddKeyword) {
                TextField("Keyword", text: $newKeyword)
                Button("Add") { addKeyword() }
                Button("Cancel", role: .cancel) { newKeyword = "" }
            }
            #elseif os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingKeywordsEditor = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                }
            }
            #endif
            .onChange(of: viewModel.keywords) {
                if selectedKeyword.isEmpty, let first = viewModel.keywords.first {
                    selectedKeyword = first
                }
            }
        }
        .background(Theme.background)
        #if !os(tvOS)
        .sheet(isPresented: $showingKeywordsEditor) {
            KeywordsEditorView()
                .onDisappear {
                    Task {
                        await viewModel.loadData(using: client)
                    }
                }
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
                #endif
        }
        #endif
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
            Text("Add keywords to find matching programs")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            #if os(tvOS)
            Button {
                showingAddKeyword = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Keyword")
                }
            }
            .buttonStyle(AccentButtonStyle())
            #else
            Button {
                showingKeywordsEditor = true
            } label: {
                HStack {
                    Image(systemName: "pencil")
                    Text("Edit Keywords")
                }
            }
            .buttonStyle(AccentButtonStyle())
            #endif
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
                            selectedProgramDetail = ProgramTopicDetail(program: item.program, channel: item.channel)
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
                    selectedProgramDetail = ProgramTopicDetail(program: item.program, channel: item.channel)
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

    #if os(tvOS)
    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var prefs = UserPreferences.load()
        guard !prefs.keywords.contains(trimmed) else {
            newKeyword = ""
            return
        }
        prefs.keywords.append(trimmed)
        prefs.save()
        newKeyword = ""
        Task {
            await viewModel.loadData(using: client)
        }
    }

    private func removeKeyword(_ keyword: String) {
        var prefs = UserPreferences.load()
        prefs.keywords.removeAll { $0 == keyword }
        prefs.save()
        if selectedKeyword == keyword {
            selectedKeyword = prefs.keywords.first ?? ""
        }
        Task {
            await viewModel.loadData(using: client)
        }
    }
    #endif
}

// Helper struct for sheet binding
private struct ProgramTopicDetail: Identifiable {
    var id: String { "\(program.id)-\(channel.id)" }
    let program: Program
    let channel: Channel
}

#Preview {
    TopicsView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
