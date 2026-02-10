//
//  RecordingDetailView.swift
//  nextpvr-apple-client
//
//  Recording detail view
//

import SwiftUI

struct RecordingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState

    let recording: Recording

    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        #if os(tvOS)
        tvOSContent
            .alert("Error", isPresented: .constant(deleteError != nil)) {
                Button("OK") { deleteError = nil }
            } message: {
                if let error = deleteError {
                    Text(error)
                }
            }
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingLG) {
                    headerSection
                    infoSection
                    if let desc = recording.desc, !desc.isEmpty {
                        descriptionSection(desc)
                    }
                    actionSection
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Recording Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Error", isPresented: .constant(deleteError != nil)) {
                Button("OK") { deleteError = nil }
            } message: {
                if let error = deleteError {
                    Text(error)
                }
            }
        }
        #endif
    }

    #if os(tvOS)
    private var tvOSContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    // Channel icon + name
                    HStack(spacing: Theme.spacingMD) {
                        if let channelId = recording.channelId {
                            CachedAsyncImage(url: client.channelIconURL(channelId: channelId)) { image in
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
                        }

                        if let channel = recording.channel {
                            Text(channel)
                                .font(.title3)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    // Recording name
                    Text(recording.name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.textPrimary)

                    // Date | Time | Duration
                    HStack {
                        if let date = recording.startDate {
                            Text(date, style: .date)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        Spacer()

                        if let start = recording.startDate, let end = recording.endDate {
                            HStack(spacing: Theme.spacingXS) {
                                Text(start, style: .time)
                                Text("-")
                                Text(end, style: .time)
                            }
                            .foregroundStyle(Theme.textSecondary)
                        }

                        Spacer()

                        if let duration = recording.durationMinutes {
                            Text("\(duration) min")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .font(.subheadline)

                    // Description
                    if let desc = recording.desc, !desc.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.spacingSM) {
                            Text("Description")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)

                            Text(tvOSDescriptionWithGenres(desc))
                                .font(.body)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                    }

                    // Action buttons
                    VStack(spacing: Theme.spacingMD) {
                        if recording.recordingStatus == .recording {
                            Button {
                                playRecording()
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Play from Beginning")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AccentButtonStyle())

                            if recording.channelId != nil {
                                Button {
                                    playLive()
                                } label: {
                                    HStack {
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                        Text("Watch Live")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                        } else if recording.recordingStatus.isPlayable {
                            Button {
                                playRecording()
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Play")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AccentButtonStyle())
                        }

                        Button(role: .destructive) {
                            deleteRecording()
                        } label: {
                            HStack {
                                if isDeleting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "trash")
                                }
                                Text(recording.recordingStatus.isScheduled ? "Cancel Recording" : "Delete")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isDeleting)
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

    private func tvOSDescriptionWithGenres(_ desc: String) -> String {
        var result = desc
        if let genres = recording.genres, !genres.isEmpty {
            result += "\n\nCategories: " + genres.joined(separator: ", ")
        }
        return result
    }
    #endif

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack {
                // Status badge
                Text(recording.recordingStatus.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, Theme.spacingSM)
                    .padding(.vertical, Theme.spacingXS)
                    .background(statusColor.opacity(0.2))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())

                Spacer()

                if recording.recurring == true {
                    Label("Recurring", systemImage: "repeat")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Text(recording.name)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)

            if let subtitle = recording.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var infoSection: some View {
        VStack(spacing: Theme.spacingSM) {
            if let channel = recording.channel {
                infoRow(icon: "tv", label: "Channel", value: channel)
            }

            if let date = recording.startDate {
                infoRow(icon: "calendar", label: "Date", value: date.formatted(date: .long, time: .omitted))
            }

            if let start = recording.startDate, let end = recording.endDate {
                infoRow(icon: "clock", label: "Time", value: "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
            }

            if let duration = recording.durationMinutes {
                infoRow(icon: "timer", label: "Duration", value: "\(duration) minutes")
            }

            if let size = recording.fileSizeFormatted {
                infoRow(icon: "doc", label: "Size", value: size)
            }

            if let quality = recording.quality {
                infoRow(icon: "sparkles.tv", label: "Quality", value: quality)
            }
        }
        .padding()
        .cardStyle()
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.textPrimary)
        }
        .font(.subheadline)
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
            if recording.recordingStatus == .recording {
                Button {
                    playRecording()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Play from Beginning")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())

                if recording.channelId != nil {
                    Button {
                        playLive()
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text("Watch Live")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else if recording.recordingStatus.isPlayable {
                Button {
                    playRecording()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
            }

            Button(role: .destructive) {
                deleteRecording()
            } label: {
                HStack {
                    if isDeleting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text(recording.recordingStatus.isScheduled ? "Cancel Recording" : "Delete")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isDeleting)
        }
        .padding(.top, Theme.spacingMD)
    }

    private var statusColor: Color {
        switch recording.recordingStatus {
        case .pending:
            return Theme.warning
        case .recording:
            return Theme.recording
        case .ready:
            return Theme.success
        case .failed, .deleted:
            return Theme.error
        case .conflict:
            return Theme.warning
        }
    }

    private func playRecording() {
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
                deleteError = error.localizedDescription
            }
        }
    }

    private func playLive() {
        guard let channelId = recording.channelId else { return }
        Task {
            do {
                let url = try await client.liveStreamURL(channelId: channelId)
                appState.playStream(
                    url: url,
                    title: recording.name
                )
                dismiss()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func deleteRecording() {
        isDeleting = true

        Task {
            do {
                try await client.cancelRecording(recordingId: recording.id)
                isDeleting = false
                dismiss()
            } catch {
                deleteError = error.localizedDescription
                isDeleting = false
            }
        }
    }
}

#Preview {
    RecordingDetailView(recording: .preview)
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
