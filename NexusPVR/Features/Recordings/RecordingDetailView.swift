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
    private var canPlayInProgress: Bool { UserPreferences.load().currentGPUAPI == .pixelbuffer }

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
                    if recording.desc != nil || recording.seriesInfo != nil {
                        descriptionSection
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
                    // Recording name
                    HStack(alignment: .top, spacing: 8) {
                        Text(recording.cleanName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if recording.isNew { NewBadge() }
                    }

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
                    if recording.desc != nil || recording.seriesInfo != nil {
                        VStack(alignment: .leading, spacing: Theme.spacingSM) {
                            Text("Description")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)

                            if let desc = recording.desc, !desc.isEmpty {
                                Text(tvOSDescriptionWithGenres(desc))
                                    .font(.body)
                                    .foregroundStyle(Theme.textSecondary)
                            }

                            if let series = recording.seriesInfo {
                                Text(series.displayString)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(Theme.accent)
                            }
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
                                    Text(canPlayInProgress ? "Play from Beginning" : "Play from Beginning (requires PixelBuffer)")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TVPopupActionButtonStyle(variant: .accent))
                            .disabled(!canPlayInProgress)

                            if let position = recording.playbackPosition, position > 10 {
                                Button {
                                    playRecording()
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.clockwise")
                                        Text(canPlayInProgress ? "Resume" : "Resume (requires PixelBuffer)")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TVPopupActionButtonStyle(variant: .secondary))
                                .disabled(!canPlayInProgress)
                            }

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
                                .buttonStyle(TVPopupActionButtonStyle(variant: .secondary))
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
                            .buttonStyle(TVPopupActionButtonStyle(variant: .accent))

                            if recording.hasResumePosition {
                                Button {
                                    playFromBeginning()
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.counterclockwise")
                                        Text("Watch from Beginning")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TVPopupActionButtonStyle(variant: .secondary))
                            }
                        }

                        #if DISPATCHERPVR
                        let canManage = appState.canManageRecordings
                        #else
                        let canManage = true
                        #endif

                        if canManage {
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
                            .buttonStyle(TVPopupActionButtonStyle(variant: .secondary))
                            .disabled(isDeleting)
                        } else {
                            Label("Managing recordings requires admin permissions", systemImage: "lock.fill")
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

            HStack(alignment: .top, spacing: 8) {
                Text(recording.cleanName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if recording.isNew { NewBadge() }
            }

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

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Description")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            if let desc = recording.desc, !desc.isEmpty {
                Text(desc)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
            }

            if let series = recording.seriesInfo {
                Text(series.displayString)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var actionSection: some View {
        VStack(spacing: Theme.spacingMD) {
            if recording.recordingStatus == .recording {
                #if !DISPATCHERPVR
                Button {
                    playFromBeginning()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text(canPlayInProgress ? "Play from Beginning" : "Play from Beginning (requires PixelBuffer)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!canPlayInProgress)

                if let position = recording.playbackPosition, position > 10 {
                    Button {
                        playRecording()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text(canPlayInProgress ? "Resume" : "Resume (requires PixelBuffer)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!canPlayInProgress)
                }
                #endif

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

                if recording.hasResumePosition {
                    Button {
                        playFromBeginning()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Watch from Beginning")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            #if DISPATCHERPVR
            let canManage = appState.canManageRecordings
            #else
            let canManage = true
            #endif

            if canManage {
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
            } else {
                Label("Managing recordings requires admin permissions", systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.top, Theme.spacingMD)
    }

    private var statusColor: Color {
        recording.recordingStatus.statusColor
    }

    private func playRecording() {
        if recording.isWatched {
            playFromBeginning()
            return
        }
        Task {
            do {
                try await RecordingPlaybackHelper.play(
                    recording: recording, using: client, appState: appState, dismiss: { dismiss() }
                )
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func playFromBeginning() {
        Task {
            do {
                try await RecordingPlaybackHelper.playFromBeginning(
                    recording: recording, using: client, appState: appState, dismiss: { dismiss() }
                )
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func playLive() {
        Task {
            do {
                try await RecordingPlaybackHelper.playLive(
                    recording: recording, using: client, appState: appState, dismiss: { dismiss() }
                )
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

#if os(tvOS)
private struct TVPopupActionButtonStyle: ButtonStyle {
    enum Variant {
        case accent
        case secondary
    }

    let variant: Variant
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.spacingLG)
            .padding(.vertical, Theme.spacingMD)
            .frame(maxWidth: .infinity)
            .background(backgroundColor(configuration: configuration))
            .foregroundStyle(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusMD)
                    .stroke(isFocused ? Color.white : Color.clear, lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : isFocused ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.14), value: isFocused)
    }

    private var foregroundColor: Color {
        isEnabled ? .white : Theme.textTertiary
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        let base: Color = {
            switch variant {
            case .accent: return Theme.accent
            case .secondary: return Theme.surfaceElevated
            }
        }()
        if !isEnabled { return Theme.textTertiary.opacity(0.5) }
        if configuration.isPressed { return base.opacity(0.75) }
        return base
    }
}
#endif

#Preview {
    RecordingDetailView(recording: .preview)
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
