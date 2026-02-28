//
//  ProgramDetailView.swift
//  nextpvr-apple-client
//
//  Program detail sheet with recording options
//

import SwiftUI

struct ProgramDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState

    let program: Program
    let channel: Channel

    @State private var isScheduling = false
    @State private var scheduleError: String?
    @State private var isScheduled: Bool
    @State private var existingRecordingId: Int?
    @State private var completedRecording: Recording?
    @State private var didChangeRecording = false

    var onRecordingChanged: (() -> Void)? = nil

    init(program: Program, channel: Channel, initialRecordingId: Int? = nil, initialCompletedRecording: Recording? = nil, onRecordingChanged: (() -> Void)? = nil) {
        self.program = program
        self.channel = channel
        self.onRecordingChanged = onRecordingChanged
        _isScheduled = State(initialValue: initialRecordingId != nil)
        _existingRecordingId = State(initialValue: initialRecordingId)
        _completedRecording = State(initialValue: initialCompletedRecording)
    }

    var body: some View {
        #if os(tvOS)
        tvOSContent
            .alert("Error", isPresented: .constant(scheduleError != nil)) {
                Button("OK") { scheduleError = nil }
            } message: {
                if let error = scheduleError {
                    Text(error)
                }
            }
            .task {
                await checkIfScheduled()
            }
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    headerSection
                    infoSection
                    if let desc = program.desc, !desc.isEmpty {
                        descriptionSection(desc)
                    }
                    actionSection
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Program Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Error", isPresented: .constant(scheduleError != nil)) {
                Button("OK") { scheduleError = nil }
            } message: {
                if let error = scheduleError {
                    Text(error)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 600)
        #endif
        .task {
            await checkIfScheduled()
        }
        #endif
    }

    #if os(tvOS)
    private var tvOSContent: some View {
        VStack(spacing: 0) {
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    // Row 1: Icon | Channel name
                    HStack(spacing: Theme.spacingMD) {
                        CachedAsyncImage(url: try? client.channelIconURL(channelId: channel.id)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Image(systemName: "tv")
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .frame(width: 60, height: 60)
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))

                        Text(channel.name)
                            .font(.title3)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // Row 2: Program name (full width)
                    Text(program.name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("program-detail-name")

                    // Row 3: Date | Start time - End time | Duration
                    HStack {
                        Text(program.startDate, style: .date)
                            .foregroundStyle(Theme.textSecondary)

                        Spacer()

                        HStack(spacing: Theme.spacingXS) {
                            Text(program.startDate, style: .time)
                            Text("-")
                            Text(program.endDate, style: .time)
                        }
                        .foregroundStyle(Theme.textSecondary)

                        Spacer()

                        Text("\(program.durationMinutes) min")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.subheadline)

                    // Description section
                    if program.desc != nil || program.genres != nil {
                        VStack(alignment: .leading, spacing: Theme.spacingSM) {
                            Text("Description")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)

                            // Description + categories appended
                            Text(descriptionWithCategories)
                                .font(.body)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                    }

                    // Action buttons
                    VStack(spacing: Theme.spacingMD) {
                        if let recording = completedRecording {
                            Button {
                                playRecording(recording)
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle.fill")
                                    Text("Watch Recording")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AccentButtonStyle())
                        }

                        if program.isCurrentlyAiring {
                            Button {
                                watchLive()
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Watch Live")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AccentButtonStyle())
                        }

                        #if DISPATCHERPVR
                        let canRecord = appState.canManageRecordings
                        #else
                        let canRecord = true
                        #endif

                        if !program.hasEnded && canRecord {
                            if isScheduled {
                                Button {
                                    scheduleRecording()
                                } label: {
                                    HStack {
                                        if isScheduling {
                                            ProgressView()
                                                .tint(.white)
                                        } else if completedRecording != nil {
                                            Image(systemName: "trash")
                                            Text("Remove Recording")
                                        } else {
                                            Image(systemName: "xmark.circle")
                                            Text("Cancel Recording")
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(isScheduling)
                                .accessibilityIdentifier("cancel-recording-button")
                            } else {
                                Button {
                                    scheduleRecording()
                                } label: {
                                    HStack {
                                        if isScheduling {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "record.circle")
                                            Text("Record")
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(isScheduling)
                                .accessibilityIdentifier("record-button")
                            }
                        } else if !program.hasEnded && !canRecord {
                            Label("Recording requires admin permissions", systemImage: "lock.fill")
                                .font(.subheadline)
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }
                .padding(Theme.spacingLG)
            }
        }
        .frame(width: 800)
        .frame(maxHeight: 800)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
    }

    private var descriptionWithCategories: String {
        var result = program.desc ?? ""
        if let genres = program.genres, !genres.isEmpty {
            if !result.isEmpty {
                result += "\n\n"
            }
            result += "Categories: " + genres.joined(separator: ", ")
        }
        return result.isEmpty ? "No description available." : result
    }
    #endif

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack {
                CachedAsyncImage(url: try? client.channelIconURL(channelId: channel.id)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    Image(systemName: "tv")
                        .foregroundStyle(Theme.textTertiary)
                }
                #if os(tvOS)
                .frame(width: 60, height: 60)
                #else
                .frame(width: 40, height: 40)
                #endif

                VStack(alignment: .leading) {
                    Text(channel.name)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Channel \(channel.number)")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                if program.isCurrentlyAiring {
                    Label("Live", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }

            Text(program.name)
                #if os(tvOS)
                .font(.title3)
                #else
                .font(.title2)
                #endif
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("program-detail-name")

            if let subtitle = program.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var infoSection: some View {
        VStack(spacing: Theme.spacingSM) {
            HStack {
                Label {
                    Text(program.startDate, style: .date)
                } icon: {
                    Image(systemName: "calendar")
                }
                .foregroundStyle(Theme.textSecondary)

                Spacer()

                Label {
                    Text("\(program.durationMinutes) min")
                } icon: {
                    Image(systemName: "clock")
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .font(.subheadline)

            HStack {
                Text(program.startDate, style: .time)
                Text("-")
                Text(program.endDate, style: .time)
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)

            if let genres = program.genres, !genres.isEmpty {
                HStack {
                    ForEach(genres, id: \.self) { genre in
                        Text(genre)
                            .font(.caption)
                            .padding(.horizontal, Theme.spacingSM)
                            .padding(.vertical, Theme.spacingXS)
                            .background(Theme.surfaceElevated)
                            .clipShape(Capsule())
                    }
                }
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding()
        .cardStyle()
    }

    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Description")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text(description)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var actionSection: some View {
        VStack(spacing: Theme.spacingMD) {
            if let recording = completedRecording {
                Button {
                    playRecording(recording)
                } label: {
                    HStack {
                        Image(systemName: "play.circle.fill")
                        Text("Watch Recording")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
            }

            if program.isCurrentlyAiring {
                Button {
                    watchLive()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Watch Live")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
                .accessibilityIdentifier("watch-live-button")
            }

            #if DISPATCHERPVR
            let canRecord = appState.canManageRecordings
            #else
            let canRecord = true
            #endif

            if !program.hasEnded && canRecord {
                if isScheduled {
                    Button {
                        scheduleRecording()
                    } label: {
                        HStack {
                            if isScheduling {
                                ProgressView()
                                    .tint(.white)
                            } else if completedRecording != nil {
                                Image(systemName: "trash")
                                Text("Remove Recording")
                            } else {
                                Image(systemName: "xmark.circle")
                                Text("Cancel Recording")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isScheduling)
                    .accessibilityIdentifier("cancel-recording-button")
                } else {
                    Button {
                        scheduleRecording()
                    } label: {
                        HStack {
                            if isScheduling {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "record.circle")
                                Text("Record")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(isScheduling)
                    .accessibilityIdentifier("record-button")
                }
            } else if !program.hasEnded && !canRecord {
                Label("Recording requires admin permissions", systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
            }
        }
        #if !os(tvOS)
        .padding(.top, Theme.spacingMD)
        #endif
    }

    private func playRecording(_ recording: Recording) {
        Task {
            do {
                let url = try await client.recordingStreamURL(recordingId: recording.id)
                appState.playStream(
                    url: url,
                    title: recording.name,
                    recordingId: recording.id,
                    resumePosition: recording.playbackPosition
                )
                dismiss()
            } catch {
                scheduleError = error.localizedDescription
            }
        }
    }

    private func watchLive() {
        // Use the direct stream URL from channel if available
        if let urlString = channel.streamURL, let url = URL(string: urlString) {
            appState.playStream(url: url, title: "\(channel.name) - \(program.name)", channelId: channel.id, channelName: channel.name)
            dismiss()
        } else {
            // Fall back to API call if streamURL not available
            Task {
                do {
                    let url = try await client.liveStreamURL(channelId: channel.id)
                    appState.playStream(url: url, title: "\(channel.name) - \(program.name)", channelId: channel.id, channelName: channel.name)
                    dismiss()
                } catch {
                    scheduleError = error.localizedDescription
                }
            }
        }
    }

    private func checkIfScheduled() async {
        do {
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            let allRecordings = completed + recording + scheduled

            if let recording = allRecordings.first(where: { $0.epgEventId == program.id }) {
                isScheduled = true
                existingRecordingId = recording.id
            }

            // Check for a completed recording with the same name
            let programName = program.name.lowercased().trimmingCharacters(in: .whitespaces)
            if let existing = completed.first(where: {
                $0.recordingStatus == .ready &&
                $0.name.lowercased().trimmingCharacters(in: .whitespaces) == programName
            }) {
                completedRecording = existing
            }
        } catch {
            // Silently fail - if we can't check, assume not scheduled
        }
    }

    private func scheduleRecording() {
        isScheduling = true
        scheduleError = nil

        Task {
            do {
                if isScheduled, let recordingId = existingRecordingId {
                    // Cancel existing recording
                    try await client.cancelRecording(recordingId: recordingId)
                    isScheduled = false
                    existingRecordingId = nil
                } else {
                    // Schedule new recording
                    try await client.scheduleRecording(eventId: program.id)
                    isScheduled = true
                    // Reload to get the recording ID
                    await checkIfScheduled()
                }
                didChangeRecording = true
                onRecordingChanged?()
                isScheduling = false
            } catch {
                scheduleError = error.localizedDescription
                isScheduling = false
            }
        }
    }
}

#Preview {
    ProgramDetailView(
        program: .preview,
        channel: Channel(id: 1, name: "ABC", number: 7)
    )
    .environmentObject(PVRClient())
    .environmentObject(AppState())
    .preferredColorScheme(.dark)
}
