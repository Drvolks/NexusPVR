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
    @Environment(\.requestNavBarFocus) private var requestNavBarFocus
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker (tvOS and macOS only — iOS uses floating nav bar picker)
                #if os(tvOS)
                Picker("Filter", selection: $filterSelection) {
                    if viewModel.hasActiveRecordings {
                        Text("Recording").tag(RecordingsFilter.recording)
                    }
                    Text("Completed").tag(RecordingsFilter.completed)
                    Text("Scheduled").tag(RecordingsFilter.scheduled)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("recordings-filter")
                .onMoveCommand { direction in
                    if direction == .up {
                        requestNavBarFocus()
                    }
                }
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
                .padding(.horizontal)
                .padding(.vertical, Theme.spacingSM)
                .background(Theme.background)
                #elseif os(macOS)
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
            .sheet(item: $selectedRecording) { recording in
                RecordingDetailView(recording: recording)
                    .environmentObject(client)
                    .environmentObject(appState)
            }
            .confirmationDialog("Play Recording", isPresented: .constant(inProgressRecording != nil), presenting: inProgressRecording) { recording in
                #if !DISPATCHERPVR
                Button("Play from Beginning") {
                    playRecordingFromBeginning(recording)
                    inProgressRecording = nil
                }
                if let position = recording.playbackPosition, position > 10 {
                    Button("Resume") {
                        playRecording(recording)
                        inProgressRecording = nil
                    }
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
                Text("\(recording.name) is currently recording.")
            }
            .alert("Error", isPresented: .constant(deleteError != nil)) {
                Button("OK") { deleteError = nil }
            } message: {
                if let error = deleteError {
                    Text(error)
                }
            }
        }
        .background(Theme.background)
        .task {
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
            appState.recordingsHasActive = viewModel.hasActiveRecordings
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
            Task { appState.recordingsHasActive = viewModel.hasActiveRecordings }
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
            Button {
                playRecordingFromBeginning(recording)
            } label: {
                Label("Play from Beginning", systemImage: "play.fill")
            }
            if let position = recording.playbackPosition, position > 10 {
                Button {
                    playRecording(recording)
                } label: {
                    Label("Resume", systemImage: "arrow.clockwise")
                }
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
        ScrollView {
            LazyVStack(spacing: Theme.spacingMD) {
                ForEach(vm.standaloneRecordings) { recording in
                    tvOSRecordingRow(recording)
                }

                ForEach(vm.seriesGroups) { group in
                    seriesSectionTV(group)
                }
            }
            .padding()
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
    private func tvOSRecordingRow(_ recording: Recording) -> some View {
        RecordingRowTV(
            recording: recording,
            onPlay: { playRecording(recording) },
            onShowDetails: { selectedRecording = recording },
            onDelete: { deleteRecording(recording) },
            durationMismatch: viewModel.durationMismatches[recording.id],
            durationVerified: viewModel.durationVerified.contains(recording.id),
            durationUnverifiable: viewModel.durationUnverifiable.contains(recording.id)
        )
        .contextMenu {
            recordingContextMenu(for: recording)
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func seriesSectionTV(_ group: SeriesGroup) -> some View {
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
                tvOSRecordingRow(recording)
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
                playRecording(recording)
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
        .listRowBackground(Theme.surface)
    }

    private func seriesRecordingRow(_ recording: Recording) -> some View {
        HStack(alignment: .center, spacing: Theme.spacingMD) {
            seriesStatusIcon(recording)

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
                playRecording(recording)
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
        .listRowBackground(Theme.surface)
    }
    @ViewBuilder
    private func seriesStatusIcon(_ recording: Recording) -> some View {
        let sport = SportDetector.detect(from: recording)
        let watchProgress: Double? = {
            guard let position = recording.playbackPosition,
                  let duration = recording.duration,
                  duration > 0, position > 0 else { return nil }
            return min(1.0, Double(position) / Double(duration))
        }()

        if recording.recordingStatus.isCompleted, let progress = watchProgress {
            WatchProgressCircle(progress: progress, size: 44, sport: sport)
        } else if recording.recordingStatus.isCompleted {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.2))
                    .frame(width: 44, height: 44)
                Image(systemName: sport?.sfSymbol ?? "play.fill")
                    .font(.system(size: 44 * 0.38))
                    .foregroundStyle(Theme.accent)
            }
        } else {
            let statusColor: Color = {
                switch recording.recordingStatus {
                case .pending, .conflict: return Theme.warning
                case .recording: return Theme.recording
                case .ready: return Theme.success
                case .failed, .deleted: return Theme.error
                }
            }()
            let statusIcon: String = {
                switch recording.recordingStatus {
                case .pending: return "clock"
                case .recording: return "record.circle"
                case .ready: return "checkmark.circle"
                case .failed: return "exclamationmark.triangle"
                case .conflict: return "exclamationmark.triangle"
                case .deleted: return "trash"
                }
            }()
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                Image(systemName: sport?.sfSymbol ?? statusIcon)
                    .font(.system(size: 44 * 0.38))
                    .foregroundStyle(statusColor)
            }
        }
    }
    #endif

    private func playRecording(_ recording: Recording) {
        if recording.isWatched {
            playRecordingFromBeginning(recording)
            return
        }
        Task {
            do {
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
                try await client.setRecordingPosition(recordingId: recording.id, positionSeconds: 0)
                let url = try await viewModel.playRecording(recording)
                appState.playStream(
                    url: url,
                    title: recording.name,
                    recordingId: recording.id,
                    resumePosition: 0,
                    isRecordingInProgress: recording.recordingStatus == .recording
                )
                NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func playRecordingLive(_ recording: Recording) {
        guard let channelId = recording.channelId else { return }
        Task {
            do {
                let url = try await client.liveStreamURL(channelId: channelId)
                appState.playStream(
                    url: url,
                    title: recording.name,
                    channelId: channelId,
                    channelName: recording.channel ?? "Channel \(channelId)"
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

#Preview {
    RecordingsListView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
