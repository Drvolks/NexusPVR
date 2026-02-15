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
    private let manageTag = "__manage__"
    #endif

    private var filteredPrograms: [MatchingProgram] {
        guard !selectedKeyword.isEmpty else { return viewModel.matchingPrograms }
        return viewModel.matchingPrograms.filter { $0.matchedKeyword == selectedKeyword }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Keyword tabs
                #if os(tvOS)
                Picker("Topic", selection: $selectedKeyword) {
                    ForEach(viewModel.keywords, id: \.self) { keyword in
                        Text(keyword).tag(keyword)
                    }
                    Text("Manage").tag(manageTag)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("keyword-tabs")
                .padding(.horizontal)
                .padding(.vertical, Theme.spacingSM)
                .background(Theme.background)
                #else
                if !viewModel.keywords.isEmpty {
                    HStack {
                        Picker("Topic", selection: $selectedKeyword) {
                            ForEach(viewModel.keywords, id: \.self) { keyword in
                                Text(keyword).tag(keyword)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("keyword-tabs")

                        #if os(macOS)
                        Spacer()
                        Button {
                            showingKeywordsEditor = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityIdentifier("edit-keywords-button")
                        #endif
                    }
                    .padding(.horizontal)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Theme.surface)
                }
                #endif

                // Content
                Group {
                    contentView
                }
            }
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
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingKeywordsEditor = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityIdentifier("edit-keywords-button")
                }
            }
            #endif
            .onChange(of: viewModel.keywords) {
                #if os(tvOS)
                if selectedKeyword.isEmpty {
                    selectedKeyword = viewModel.keywords.first ?? manageTag
                } else if selectedKeyword != manageTag && !viewModel.keywords.contains(selectedKeyword) {
                    selectedKeyword = viewModel.keywords.first ?? manageTag
                }
                #else
                if selectedKeyword.isEmpty, let first = viewModel.keywords.first {
                    selectedKeyword = first
                }
                #endif
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

    @ViewBuilder
    private var contentView: some View {
        #if os(tvOS)
        if selectedKeyword == manageTag {
            manageKeywordsView
        } else if viewModel.isLoading && viewModel.matchingPrograms.isEmpty {
            loadingView
        } else if let error = viewModel.error {
            errorView(error)
        } else if filteredPrograms.isEmpty {
            noMatchesView
        } else {
            programsList
        }
        #else
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
        #endif
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

            Button {
                showingKeywordsEditor = true
            } label: {
                HStack {
                    Image(systemName: "pencil")
                    Text("Edit Keywords")
                }
            }
            .buttonStyle(AccentButtonStyle())
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
                    },
                    onShowDetails: { recordingId, completedRecording in
                        selectedProgramDetail = ProgramTopicDetail(
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
        .refreshable {
            await viewModel.loadData(using: client)
        }
        #endif
    }

    #if os(tvOS)
    private var manageKeywordsView: some View {
        ScrollView {
            VStack(spacing: Theme.spacingLG) {
                ForEach(viewModel.keywords, id: \.self) { keyword in
                    Button {
                        removeKeyword(keyword)
                    } label: {
                        HStack {
                            Text(keyword)
                                .font(.tvHeadline)
                            Spacer()
                            Text("Delete")
                                .font(.tvBody)
                                .foregroundStyle(Theme.error)
                        }
                        .padding(.horizontal, Theme.spacingLG)
                        .padding(.vertical, Theme.spacingMD)
                    }
                    .buttonStyle(.card)
                }

                HStack(spacing: Theme.spacingMD) {
                    TextField("New keyword", text: $newKeyword)
                        .textFieldStyle(.plain)
                        .padding(Theme.spacingMD)
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        .accessibilityIdentifier("keyword-text-field")
                        .onSubmit { addKeyword() }

                    Button {
                        addKeyword()
                    } label: {
                        Text("Add")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("add-keyword-button")
                }
            }
            .padding(Theme.spacingXL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
        selectedKeyword = trimmed
        Task {
            await viewModel.loadData(using: client)
        }
    }

    private func removeKeyword(_ keyword: String) {
        var prefs = UserPreferences.load()
        prefs.keywords.removeAll { $0 == keyword }
        prefs.save()
        if selectedKeyword == keyword {
            selectedKeyword = prefs.keywords.first ?? manageTag
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
    var recordingId: Int? = nil
    var completedRecording: Recording? = nil
}

#Preview {
    TopicsView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
