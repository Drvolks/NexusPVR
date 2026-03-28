//
//  RecordingsListView.swift
//  nextpvr-apple-client
//
//  Recordings list view
//

import SwiftUI

struct RecordingsListView: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    @State private var selectedRecording: Recording?
    @State private var deleteError: String?

    var body: some View {
        RecordingsListContentView(
            client: client,
            appState: appState,
            selectedRecording: $selectedRecording,
            deleteError: $deleteError
        )
    }
}

private struct RecordingsListContentView: View {
    @ObservedObject var client: PVRClient
    @ObservedObject var appState: AppState
    @StateObject private var viewModel: RecordingsViewModel
    @Binding var selectedRecording: Recording?
    @Binding var deleteError: String?
    @State private var inProgressRecording: Recording?
    @State private var resumeRecording: Recording?
    @State private var filterSelection: RecordingsFilter = .completed
    @State private var suppressNextFilterSelectionChange = false

    init(client: PVRClient, appState: AppState,
         selectedRecording: Binding<Recording?>,
         deleteError: Binding<String?>) {
        self.client = client
        self.appState = appState
        self._selectedRecording = selectedRecording
        self._deleteError = deleteError
        self._viewModel = StateObject(wrappedValue: RecordingsViewModel(client: client))
    }

    @Environment(\.scenePhase) private var scenePhase
    #if os(tvOS)
    @Environment(\.requestSidebarFocus) private var requestSidebarFocus
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker (tvOS and macOS only — iOS uses floating nav bar picker)
                #if os(macOS)
                Picker("Filter", selection: $filterSelection) {
                    if viewModel.hasActiveRecordings {
                        Text("Recording").tag(RecordingsFilter.recording)
                    }
                    Text("Completed").tag(RecordingsFilter.completed)
                    Text("Scheduled").tag(RecordingsFilter.scheduled)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("recordings-filter")
                .padding(.horizontal)
                .padding(.vertical, Theme.spacingSM)
                .background(Theme.background)
                .onChange(of: filterSelection) {
                    if suppressNextFilterSelectionChange {
                        suppressNextFilterSelectionChange = false
                        return
                    }
                    appState.setRecordingsFilter(filterSelection, userInitiated: true)
                    Task { viewModel.filter = filterSelection }
                }
                .onChange(of: viewModel.filter) {
                    if filterSelection != viewModel.filter {
                        suppressNextFilterSelectionChange = true
                        filterSelection = viewModel.filter
                    }
                }
                #endif

                // Content
                Group {
                    if viewModel.isLoading && viewModel.filteredRecordings.isEmpty {
                        loadingView
                    } else if let error = viewModel.error, viewModel.filteredRecordings.isEmpty {
                        errorView(error)
                    } else if viewModel.filteredRecordings.isEmpty {
                        emptyView(viewModel)
                    } else {
                        recordingsList(viewModel)
                    }
                }
            }
            .accessibilityIdentifier("recordings-view")
            #if os(iOS)
            .sidebarMenuToolbar()
            .navigationTitle(appState.recordingsFilter.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $selectedRecording) { recording in
                RecordingDetailView(recording: recording)
                    .environmentObject(client)
                    .environmentObject(appState)
            }
            .confirmationDialog("Play Recording", isPresented: .constant(inProgressRecording != nil), presenting: inProgressRecording) { recording in
                #if !DISPATCHERPVR
                let canPlay = UserPreferences.load().currentGPUAPI == .pixelbuffer
                Button(canPlay ? "Play from Beginning" : "Play from Beginning (requires PixelBuffer)") {
                    playRecordingFromBeginning(recording)
                    inProgressRecording = nil
                }
                .disabled(!canPlay)
                if let position = recording.playbackPosition, position > 10 {
                    Button(canPlay ? "Resume" : "Resume (requires PixelBuffer)") {
                        playRecording(recording)
                        inProgressRecording = nil
                    }
                    .disabled(!canPlay)
                }
                #endif
                if recording.channelId != nil {
                    Button("Watch Live") {
                        playRecordingLive(recording)
                        inProgressRecording = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    inProgressRecording = nil
                }
            } message: { recording in
                let canPlay = UserPreferences.load().currentGPUAPI == .pixelbuffer
                if canPlay {
                    Text("\(recording.name) is currently recording.")
                } else {
                    Text("Watching in-progress recordings requires the PixelBuffer renderer. You can change this in Settings > Playback.")
                }
            }
            .alert("Error", isPresented: .constant(deleteError != nil)) {
                Button("OK") { deleteError = nil }
            } message: {
                if let error = deleteError {
                    Text(error)
                }
            }
            #if os(tvOS)
            .onExitCommand {
                requestSidebarFocus()
            }
            #endif
        }
        #if os(tvOS)
        .background(.ultraThinMaterial)
        #else
        .background(Theme.background)
        #endif
        .task {
            // Apply user-selected filter before loading so the view shows the correct tab
            if appState.recordingsFilterUserOverride {
                viewModel.filter = appState.recordingsFilter
            }
            await viewModel.loadRecordings()
            if !appState.recordingsFilterUserOverride {
                let initialFilter: RecordingsFilter = viewModel.hasActiveRecordings ? .recording : .completed
                if viewModel.filter != initialFilter {
                    viewModel.filter = initialFilter
                }
                if appState.recordingsFilter != initialFilter {
                    appState.recordingsFilter = initialFilter
                }
            }
            appState.activeRecordingCount = viewModel.activeRecordings.count
            if appState.recordingsFilter != viewModel.filter {
                appState.recordingsFilter = viewModel.filter
            }
            if filterSelection != viewModel.filter {
                suppressNextFilterSelectionChange = true
                filterSelection = viewModel.filter
            }
        }
        .onChange(of: appState.recordingsFilter) {
            if viewModel.filter != appState.recordingsFilter {
                Task { viewModel.filter = appState.recordingsFilter }
            }
        }
        .onChange(of: viewModel.filter) {
            if appState.recordingsFilter != viewModel.filter {
                appState.recordingsFilter = viewModel.filter
            }
            if filterSelection != viewModel.filter {
                suppressNextFilterSelectionChange = true
                filterSelection = viewModel.filter
            }
        }
        .onChange(of: viewModel.hasActiveRecordings) {
            Task { appState.activeRecordingCount = viewModel.activeRecordings.count }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingsDidChange)) { _ in
            Task {
                await viewModel.loadRecordings()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await viewModel.loadRecordings() }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: Theme.spacingMD) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.accent)
            Text("Loading recordings...")
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.warning)
            Text("Unable to load recordings")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await viewModel.loadRecordings() }
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(_ vm: RecordingsViewModel) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "recordingtape")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No recordings")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(emptyMessage(for: vm.filter))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyMessage(for filter: RecordingsFilter) -> String {
        switch filter {
        case .completed:
            return "No completed recordings."
        case .recording:
            return "No recordings in progress."
        case .scheduled:
            return "No scheduled recordings."
        }
    }

    @ViewBuilder
    private func recordingContextMenu(for recording: Recording) -> some View {
        if recording.recordingStatus == .recording {
            #if !DISPATCHERPVR
            let canPlay = UserPreferences.load().currentGPUAPI == .pixelbuffer
            Button {
                playRecordingFromBeginning(recording)
            } label: {
                Label(canPlay ? "Play from Beginning" : "Play from Beginning (requires PixelBuffer)", systemImage: "play.fill")
            }
            .disabled(!canPlay)
            if let position = recording.playbackPosition, position > 10 {
                Button {
                    playRecording(recording)
                } label: {
                    Label(canPlay ? "Resume" : "Resume (requires PixelBuffer)", systemImage: "arrow.clockwise")
                }
                .disabled(!canPlay)
            }
            #endif
            if recording.channelId != nil {
                Button {
                    playRecordingLive(recording)
                } label: {
                    Label("Watch Live", systemImage: "dot.radiowaves.left.and.right")
                }
            }
        } else if recording.recordingStatus.isPlayable {
            Button {
                playRecording(recording)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            if recording.hasResumePosition {
                Button {
                    playRecordingFromBeginning(recording)
                } label: {
                    Label("Watch from Beginning", systemImage: "arrow.counterclockwise")
                }
            }
        }

        Button {
            selectedRecording = recording
        } label: {
            Label("Details", systemImage: "info.circle")
        }
    }

    private func recordingsList(_ vm: RecordingsViewModel) -> some View {
        #if os(tvOS)
        let channelIdByName = buildChannelIdByNameMap(from: vm.filteredRecordings)
        return ScrollView {
            LazyVStack(spacing: Theme.spacingMD) {
                ForEach(vm.standaloneRecordings) { recording in
                    tvOSRecordingRow(recording, channelIdByName: channelIdByName)
                }

                ForEach(vm.seriesGroups) { group in
                    seriesSectionTV(group, channelIdByName: channelIdByName)
                }
            }
            .padding()
        }
        .onExitCommand {
            requestSidebarFocus()
        }
        #else
        List {
            ForEach(vm.standaloneRecordings) { recording in
                iOSRecordingRow(recording)
            }

            ForEach(vm.seriesGroups) { group in
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: "arrow.2.squarepath")
                        .foregroundStyle(Theme.accent)
                    Text(group.seriesName)
                        .foregroundStyle(Theme.textPrimary)
                }
                .font(.headline)
                .padding(.top, Theme.spacingSM)
                .listRowBackground(Theme.surface)
                .listRowSeparator(.hidden)

                ForEach(group.recordings) { recording in
                    seriesRecordingRow(recording)
                }
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
            await vm.loadRecordings()
        }
        #endif
    }

    #if os(tvOS)
    private func buildChannelIdByNameMap(from recordings: [Recording]) -> [String: Int] {
        var map: [String: Int] = [:]
        for recording in recordings {
            guard let channelId = recording.channelId,
                  let channelName = recording.channel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !channelName.isEmpty else { continue }
            map[channelName.lowercased()] = channelId
        }
        return map
    }

    private func tvOSRecordingRow(_ recording: Recording, channelIdByName: [String: Int]) -> some View {
        let fallbackChannelId: Int? = {
            guard let name = recording.channel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return channelIdByName[name.lowercased()]
        }()

        return RecordingRowTV(
            recording: recording,
            fallbackChannelId: fallbackChannelId,
            onPlay: {
                if recording.recordingStatus == .recording {
                    inProgressRecording = recording
                } else if recording.hasResumePosition && !recording.isWatched {
                    resumeRecording = recording
                } else {
                    playRecording(recording)
                }
            },
            onShowDetails: { selectedRecording = recording },
            onDelete: { deleteRecording(recording) },
            durationMismatch: viewModel.durationMismatches[recording.id],
            durationVerified: viewModel.durationVerified.contains(recording.id),
            durationUnverifiable: viewModel.durationUnverifiable.contains(recording.id)
        )
        .padding(.leading, Theme.spacingMD)
        .contextMenu {
            recordingContextMenu(for: recording)
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .resumeDialog(recording: recording, resumeRecording: $resumeRecording, playRecording: playRecording, playFromBeginning: playRecordingFromBeginning)
    }

    private func seriesSectionTV(_ group: SeriesGroup, channelIdByName: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack(spacing: Theme.spacingSM) {
                Image(systemName: "arrow.2.squarepath")
                Text(group.seriesName)
                    .font(.title3)
                    .fontWeight(.bold)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.top, Theme.spacingMD)

            ForEach(group.recordings) { recording in
                tvOSRecordingRow(recording, channelIdByName: channelIdByName)
            }
        }
    }
    #else
    private func iOSRecordingRow(_ recording: Recording) -> some View {
        RecordingRow(
            recording: recording,
            durationMismatch: viewModel.durationMismatches[recording.id],
            durationVerified: viewModel.durationVerified.contains(recording.id),
            durationUnverifiable: viewModel.durationUnverifiable.contains(recording.id)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if recording.recordingStatus == .recording {
                inProgressRecording = recording
            } else if recording.recordingStatus.isPlayable {
                if recording.hasResumePosition && !recording.isWatched {
                    resumeRecording = recording
                } else {
                    playRecording(recording)
                }
            } else {
                selectedRecording = recording
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            recordingContextMenu(for: recording)
            Divider()
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label(recording.recordingStatus.isScheduled ? "Cancel Recording" : "Delete", systemImage: "trash")
            }
        }
        .resumeDialog(recording: recording, resumeRecording: $resumeRecording, playRecording: playRecording, playFromBeginning: playRecordingFromBeginning)
        .listRowBackground(Theme.surface)
    }

    private func seriesRecordingRow(_ recording: Recording) -> some View {
        HStack(alignment: .center, spacing: Theme.spacingMD) {
            RecordingStatusIcon(recording: recording, size: 44)

            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                HStack {
                    if let series = recording.seriesInfo {
                        Text(series.shortDisplayString)
                            .font(.headline)
                            .foregroundStyle(Theme.accent)
                    }

                    if let subtitle = recording.subtitle, !subtitle.isEmpty {
                        let cleaned = SeriesInfo.stripPattern(from: subtitle)
                        if !cleaned.isEmpty {
                            Text(cleaned)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if let date = recording.startDate {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                if let desc = recording.desc, !desc.isEmpty {
                    Text(desc)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, Theme.spacingXS)
        .contentShape(Rectangle())
        .onTapGesture {
            if recording.recordingStatus == .recording {
                inProgressRecording = recording
            } else if recording.recordingStatus.isPlayable {
                if recording.hasResumePosition && !recording.isWatched {
                    resumeRecording = recording
                } else {
                    playRecording(recording)
                }
            } else {
                selectedRecording = recording
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            recordingContextMenu(for: recording)
            Divider()
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label(recording.recordingStatus.isScheduled ? "Cancel Recording" : "Delete", systemImage: "trash")
            }
        }
        .resumeDialog(recording: recording, resumeRecording: $resumeRecording, playRecording: playRecording, playFromBeginning: playRecordingFromBeginning)
        .listRowBackground(Theme.surface)
    }
    #endif

    private func playRecording(_ recording: Recording) {
        if recording.isWatched {
            playRecordingFromBeginning(recording)
            return
        }
        Task {
            do {
                // Use viewModel.playRecording for URL (handles stream URL logic)
                let url = try await viewModel.playRecording(recording)
                appState.playStream(
                    url: url,
                    title: recording.name,
                    recordingId: recording.id,
                    resumePosition: recording.playbackPosition,
                    isRecordingInProgress: recording.recordingStatus == .recording
                )
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func playRecordingFromBeginning(_ recording: Recording) {
        viewModel.resetPlaybackPosition(for: recording.id)
        Task {
            do {
                try await RecordingPlaybackHelper.playFromBeginning(
                    recording: recording, using: client, appState: appState
                )
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func playRecordingLive(_ recording: Recording) {
        Task {
            do {
                try await RecordingPlaybackHelper.playLive(
                    recording: recording, using: client, appState: appState
                )
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func deleteRecording(_ recording: Recording) {
        Task {
            do {
                try await viewModel.deleteRecording(recording)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }
}

private struct ResumeDialogModifier: ViewModifier {
    let recording: Recording
    @Binding var resumeRecording: Recording?
    let playRecording: (Recording) -> Void
    let playFromBeginning: (Recording) -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { resumeRecording?.id == recording.id },
            set: { if !$0 { resumeRecording = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Resume Playback", isPresented: isPresented) {
                Button("Resume") {
                    playRecording(recording)
                    resumeRecording = nil
                }
                Button("Watch from Beginning") {
                    playFromBeginning(recording)
                    resumeRecording = nil
                }
                Button("Cancel", role: .cancel) {
                    resumeRecording = nil
                }
            } message: {
                if let position = recording.playbackPosition {
                    let minutes = position / 60
                    let seconds = position % 60
                    Text("\(recording.name)\nStopped at \(minutes):\(String(format: "%02d", seconds))")
                }
            }
    }
}

private extension View {
    func resumeDialog(recording: Recording, resumeRecording: Binding<Recording?>, playRecording: @escaping (Recording) -> Void, playFromBeginning: @escaping (Recording) -> Void) -> some View {
        modifier(ResumeDialogModifier(recording: recording, resumeRecording: resumeRecording, playRecording: playRecording, playFromBeginning: playFromBeginning))
    }
}

#Preview {
    RecordingsListView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
