//
//  RecordingDetailView.swift
//  nextpvr-apple-client
//
//  Recording detail view
//

import SwiftUI

struct RecordingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: NextPVRClient
    @EnvironmentObject private var appState: AppState

    let recording: Recording

    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
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
    }

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
            if recording.recordingStatus.isCompleted {
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
        .environmentObject(NextPVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
