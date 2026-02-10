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

    init(client: PVRClient, appState: AppState,
         selectedRecording: Binding<Recording?>,
         deleteError: Binding<String?>) {
        self.client = client
        self.appState = appState
        self._selectedRecording = selectedRecording
        self._deleteError = deleteError
        self._viewModel = StateObject(wrappedValue: RecordingsViewModel(client: client))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("Filter", selection: $viewModel.filter) {
                    Text("Completed").tag(RecordingsFilter.completed)
                    if viewModel.hasActiveRecordings {
                        Text("Recording").tag(RecordingsFilter.recording)
                    }
                    Text("Scheduled").tag(RecordingsFilter.scheduled)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, Theme.spacingSM)
                .background(Theme.background)

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
            .sheet(item: $selectedRecording) { recording in
                RecordingDetailView(recording: recording)
                    .environmentObject(client)
                    .environmentObject(appState)
            }
            .confirmationDialog("Play Recording", isPresented: .constant(inProgressRecording != nil), presenting: inProgressRecording) { recording in
                Button("Play from Beginning") {
                    playRecording(recording)
                    inProgressRecording = nil
                }
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingsDidChange)) { _ in
            Task {
                await viewModel.loadRecordings()
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

    private func recordingsList(_ vm: RecordingsViewModel) -> some View {
        #if os(tvOS)
        ScrollView {
            LazyVStack(spacing: Theme.spacingMD) {
                ForEach(vm.filteredRecordings) { recording in
                    RecordingRowTV(
                        recording: recording,
                        onPlay: { playRecording(recording) },
                        onShowDetails: { selectedRecording = recording },
                        onDelete: {
                            deleteRecording(recording)
                        }
                    )
                    .contextMenu {
                        if recording.recordingStatus == .recording {
                            Button {
                                playRecording(recording)
                            } label: {
                                Label("Play from Beginning", systemImage: "play.fill")
                            }
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
                        }

                        Button {
                            selectedRecording = recording
                        } label: {
                            Label("Details", systemImage: "info.circle")
                        }

                        Button(role: .destructive) {
                            deleteRecording(recording)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
        #else
        List {
            ForEach(vm.filteredRecordings) { recording in
                RecordingRow(recording: recording)
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
                        if recording.recordingStatus == .recording {
                            Button {
                                playRecording(recording)
                            } label: {
                                Label("Play from Beginning", systemImage: "play.fill")
                            }
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
                        }

                        Button {
                            selectedRecording = recording
                        } label: {
                            Label("Details", systemImage: "info.circle")
                        }

                        Divider()

                        Button(role: .destructive) {
                            deleteRecording(recording)
                        } label: {
                            Label(recording.recordingStatus.isScheduled ? "Cancel Recording" : "Delete", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Theme.surface)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await vm.loadRecordings()
        }
        #endif
    }

    private func playRecording(_ recording: Recording) {
        Task {
            do {
                let url = try await viewModel.playRecording(recording)
                appState.playStream(
                    url: url,
                    title: recording.name,
                    recordingId: recording.id,
                    resumePosition: recording.playbackPosition
                )
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
                    title: recording.name
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
