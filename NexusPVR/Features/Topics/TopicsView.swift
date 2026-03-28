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
    @EnvironmentObject private var epgCache: EPGCache
    @StateObject private var viewModel = TopicsViewModel()
    @State private var selectedProgramDetail: ProgramTopicDetail?
    @State private var refreshTrigger = UUID()
    @State private var selectedKeyword: String = ""
    @Environment(\.scenePhase) private var scenePhase
    #if os(tvOS)
    @State private var newKeyword = ""
    #endif

    private var filteredPrograms: [MatchingProgram] {
        let nonScheduled = viewModel.matchingPrograms.filter { $0.matchedKeyword != MatchingProgram.scheduledKeyword }
        #if os(tvOS)
        let keyword = appState.selectedTopicKeyword
        guard !keyword.isEmpty else { return nonScheduled }
        return nonScheduled.filter { $0.matchedKeyword == keyword }
        #else
        guard !selectedKeyword.isEmpty else { return nonScheduled }
        return nonScheduled.filter { $0.matchedKeyword == selectedKeyword }
        #endif
    }

    #if os(iOS)
    private func updateKeywordsWithMatches() {
        var counts: [String: Int] = [:]
        for program in viewModel.matchingPrograms where program.matchedKeyword != MatchingProgram.scheduledKeyword {
            counts[program.matchedKeyword, default: 0] += 1
        }
        appState.topicKeywordMatchCounts = counts
    }
    #endif

    private func syncTopicSelection(with keywords: [String], preferFirst: Bool = false) {
        appState.topicKeywords = keywords

        guard let first = keywords.first else {
            selectedKeyword = ""
            appState.selectedTopicKeyword = ""
            return
        }

        let selection = appState.selectedTopicKeyword
        let resolved = preferFirst ? first : (keywords.contains(selection) && !selection.isEmpty ? selection : first)

        if selectedKeyword != resolved {
            selectedKeyword = resolved
        }
        if appState.selectedTopicKeyword != resolved {
            appState.selectedTopicKeyword = resolved
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(macOS)
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
                        .onChange(of: selectedKeyword) {
                            Task { appState.selectedTopicKeyword = selectedKeyword }
                        }

                        Spacer()
                        Button {
                            appState.showingKeywordsEditor = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityIdentifier("edit-keywords-button")
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
            .accessibilityIdentifier("topics-view")
            #if os(iOS)
            .sidebarMenuToolbar()
            .navigationTitle(appState.selectedTopicKeyword.isEmpty ? "Topics" : appState.selectedTopicKeyword)
            .navigationBarTitleDisplayMode(.inline)
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
            .onChange(of: viewModel.keywords) {
                #if os(tvOS)
                appState.topicKeywords = viewModel.keywords
                if !appState.showingKeywordsEditor {
                    if appState.selectedTopicKeyword.isEmpty || !viewModel.keywords.contains(appState.selectedTopicKeyword) {
                        appState.selectedTopicKeyword = viewModel.keywords.first ?? ""
                    }
                }
                #else
                syncTopicSelection(with: viewModel.keywords)
                #endif
            }
        }
        #if os(tvOS)
        .background(.ultraThinMaterial)
        #else
        .background(Theme.background)
        #endif
        #if os(macOS)
        .sheet(isPresented: $appState.showingKeywordsEditor) {
            KeywordsEditorView()
                .onDisappear {
                    Task {
                        await viewModel.loadData()
                    }
                }
                .frame(minWidth: 500, minHeight: 400)
        }
        .onChange(of: appState.showingCalendar) {
            if appState.showingCalendar {
                viewModel.epgCache = epgCache
                viewModel.client = client
                Task { await viewModel.loadData() }
            }
        }
        .sheet(isPresented: $appState.showingCalendar) {
            CalendarView(programs: viewModel.matchingPrograms)
                .environmentObject(client)
                .environmentObject(appState)
                .frame(minWidth: 700, minHeight: 500)
        }
        #endif
        .task {
            viewModel.epgCache = epgCache
            viewModel.client = client
            await viewModel.loadData()
            #if os(iOS)
            let hasValidSelection = !appState.selectedTopicKeyword.isEmpty &&
                viewModel.keywords.contains(appState.selectedTopicKeyword)
            syncTopicSelection(with: viewModel.keywords, preferFirst: !hasValidSelection)
            updateKeywordsWithMatches()
            #elseif !os(tvOS)
            syncTopicSelection(with: viewModel.keywords)
            #else
            appState.topicKeywords = viewModel.keywords
            if !appState.showingKeywordsEditor,
               (appState.selectedTopicKeyword.isEmpty || !viewModel.keywords.contains(appState.selectedTopicKeyword)) {
                appState.selectedTopicKeyword = viewModel.keywords.first ?? ""
            }
            #endif
        }
        #if os(iOS)
        .onAppear {
            // Only sync if keywords are already loaded; otherwise .task will handle it
            guard !viewModel.keywords.isEmpty else { return }
            let hasValidSelection = !appState.selectedTopicKeyword.isEmpty &&
                viewModel.keywords.contains(appState.selectedTopicKeyword)
            syncTopicSelection(with: viewModel.keywords, preferFirst: !hasValidSelection)
        }
        #endif
        #if !os(tvOS)
        .onChange(of: appState.selectedTopicKeyword) {
            if selectedKeyword != appState.selectedTopicKeyword {
                selectedKeyword = appState.selectedTopicKeyword
            }
        }
        #endif
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task {
                    await viewModel.loadData()
                    #if os(iOS)
                    updateKeywordsWithMatches()
                    #endif
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingsDidChange)) { _ in
            Task {
                await viewModel.loadData()
                #if os(iOS)
                updateKeywordsWithMatches()
                #endif
            }
        }
        #if os(iOS)
        .onChange(of: appState.selectedTab) {
            guard appState.selectedTab == .topics else { return }
            let hasValidSelection = !appState.selectedTopicKeyword.isEmpty &&
                viewModel.keywords.contains(appState.selectedTopicKeyword)
            syncTopicSelection(with: viewModel.keywords, preferFirst: !hasValidSelection)
        }
        #endif
    }

    @ViewBuilder
    private var contentView: some View {
        #if os(tvOS)
        if appState.showingKeywordsEditor {
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
        if viewModel.isLoading && viewModel.matchingPrograms.isEmpty {
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
            #if os(tvOS)
            Text("No upcoming programs match: \(appState.selectedTopicKeyword.isEmpty ? viewModel.keywords.joined(separator: ", ") : appState.selectedTopicKeyword)")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            #else
            Text("No upcoming programs match: \(appState.selectedTopicKeyword.isEmpty ? viewModel.keywords.joined(separator: ", ") : appState.selectedTopicKeyword)")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            #endif
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
            #if os(iOS)
            Color.clear
                .frame(height: 96)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            #endif
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.loadData()
        }
        #endif
    }

    #if os(tvOS)
    private var manageKeywordsView: some View {
        ScrollView {
            VStack(spacing: Theme.spacingLG) {
                HStack(spacing: Theme.spacingMD) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Theme.accent)

                    TextField("Add topic keyword", text: $newKeyword)
                        .textFieldStyle(.plain)
                        .font(.tvBody)
                        .accessibilityIdentifier("keyword-text-field")
                        .onSubmit { addKeyword() }
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, Theme.spacingMD)
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(viewModel.keywords, id: \.self) { keyword in
                    HStack(spacing: Theme.spacingMD) {
                        Text(keyword)
                            .font(.tvHeadline)
                            .foregroundStyle(.white.opacity(0.95))
                        Spacer()
                        Button(role: .destructive) {
                            removeKeyword(keyword)
                        } label: {
                            Image(systemName: "trash")
                                .font(.headline)
                                .padding(.horizontal, Theme.spacingMD)
                                .padding(.vertical, Theme.spacingSM)
                        }
                        .buttonStyle(TVManageDeleteButtonStyle())
                    }
                    .padding(.horizontal, Theme.spacingLG)
                    .padding(.vertical, Theme.spacingMD)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.guideNowPlaying)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
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
        Task {
            await viewModel.loadData()
        }
    }

    private func removeKeyword(_ keyword: String) {
        var prefs = UserPreferences.load()
        prefs.keywords.removeAll { $0 == keyword }
        prefs.save()
        if appState.selectedTopicKeyword == keyword {
            appState.selectedTopicKeyword = prefs.keywords.first ?? ""
        }
        Task {
            await viewModel.loadData()
        }
    }
    #endif
}

private struct TVManageDeleteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVManageDeleteFocusWrapper {
            configuration.label
        }
    }
}

private struct TVManageDeleteFocusWrapper<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusLG)
                    .fill(Theme.surface.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusLG)
                    .stroke(isFocused ? Theme.accent.opacity(0.95) : Color.clear, lineWidth: 2)
            )
            .shadow(color: isFocused ? Theme.accent.opacity(0.2) : .clear, radius: 6, x: 0, y: 1)
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.14), value: isFocused)
            .focusEffectDisabled()
    }
}

// Helper struct for sheet binding
struct ProgramTopicDetail: Identifiable {
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
        .environmentObject(EPGCache())
        .preferredColorScheme(.dark)
}
