//
//  TopicProgramRow.swift
//  nextpvr-apple-client
//
//  Row displaying a program matching a topic keyword
//

import SwiftUI

struct TopicProgramRow: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState

    let program: Program
    let channel: Channel
    let matchedKeyword: String
    var onRecordingChanged: (() -> Void)? = nil

    @State private var isScheduled = false
    @State private var existingRecordingId: Int?
    @State private var isProcessing = false
    @State private var existingRecording: Recording?
    @State private var earlierScheduled: Recording?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spacingMD) {
            // Left column: Sport icon or default TV icon
            ZStack {
                Circle()
                    .fill(Theme.surfaceElevated)

                if let sport = SportDetector.detect(from: program) {
                    Image(systemName: sport.sfSymbol)
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 56, height: 56)

            // Content area
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                // Row 1: Program title
                HStack {
                    Text(program.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)

                    if program.isCurrentlyAiring {
                        Spacer()
                        Label("Live", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }

                // Row 2: Channel name | Action button
                HStack {
                    Text(channel.name)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    // Action button
                    if let existing = existingRecording {
                        Button {
                            playExistingRecording(existing)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.circle.fill")
                                Text("Watch")
                                    .font(.caption)
                            }
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    } else if !program.hasEnded {
                        Button {
                            toggleRecording()
                        } label: {
                            HStack(spacing: 4) {
                                if isProcessing {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else if isScheduled {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.success)
                                    Text("Scheduled")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                } else {
                                    Image(systemName: "record.circle")
                                        .foregroundStyle(Theme.accent)
                                    Text("Record")
                                        .font(.caption)
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, Theme.spacingSM)
                            .padding(.vertical, Theme.spacingXS)
                            .background(isScheduled ? Theme.success.opacity(0.1) : Theme.accent.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessing)
                    }
                }

                // Row 3: Date | Earlier scheduled info
                HStack {
                    Text("\(program.startDate, style: .date) at \(program.startDate, style: .time)")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)

                    Spacer()

                    if let earlier = earlierScheduled {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.checkmark")
                            Text("Scheduled \(earlier.startDate ?? Date(), style: .time)")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                    }
                }
            }
        }
        .padding(.vertical, Theme.spacingSM)
        .task {
            await checkIfScheduled()
        }
    }

    private func namesAreEqual(_ name1: String, _ name2: String) -> Bool {
        let n1 = name1.lowercased().trimmingCharacters(in: .whitespaces)
        let n2 = name2.lowercased().trimmingCharacters(in: .whitespaces)
        return n1 == n2
    }

    private func checkIfScheduled() async {
        do {
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            let allRecordings = completed + recording + scheduled

            // Check if this exact program is scheduled
            if let recording = allRecordings.first(where: { $0.epgEventId == program.id }) {
                isScheduled = true
                existingRecordingId = recording.id
            }

            // Check for existing completed recording with similar name
            if let existing = completed.first(where: { recording in
                namesAreEqual(recording.name, program.name) &&
                recording.recordingStatus == .ready
            }) {
                existingRecording = existing
            }

            if let earlier = scheduled.first(where: { recording in
                namesAreEqual(recording.name, program.name) &&
                recording.epgEventId != program.id &&  // Exclude current program
                (recording.startTime ?? 0) < program.start &&
                recording.recordingStatus == .pending
            }) {
                earlierScheduled = earlier
            }
        } catch {
            // Silently fail
            #if DEBUG
            print("TopicProgramRow: Error checking recordings: \(error)")
            #endif
        }
    }

    private func toggleRecording() {
        isProcessing = true

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
                    await checkIfScheduled()
                }
                isProcessing = false

                // Notify parent that recording state changed
                onRecordingChanged?()
            } catch {
                isProcessing = false
            }
        }
    }

    private func playExistingRecording(_ recording: Recording) {
        Task {
            do {
                let url = try await client.recordingStreamURL(recordingId: recording.id)
                appState.playStream(
                    url: url,
                    title: recording.name,
                    recordingId: recording.id,
                    resumePosition: recording.playbackPosition
                )
            } catch {
                // Error playing - could show an alert but for now just fail silently
            }
        }
    }
}

// MARK: - tvOS Helper Views

#if os(tvOS)
/// Combined row for tvOS - single focusable button with action on the right
struct TopicProgramRowTV: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState

    let program: Program
    let channel: Channel
    let matchedKeyword: String
    var onRecordingChanged: (() -> Void)? = nil
    var onShowDetails: (() -> Void)? = nil

    @State private var isScheduled = false
    @State private var existingRecordingId: Int?
    @State private var isProcessing = false
    @State private var existingRecording: Recording?
    @State private var earlierScheduled: Recording?

    private var actionLabel: String {
        if existingRecording != nil {
            return "Watch Recording"
        } else if isScheduled {
            return "Scheduled"
        } else if program.hasEnded {
            return "Ended"
        } else {
            return "Record"
        }
    }

    private var actionIcon: String {
        if existingRecording != nil {
            return "play.circle.fill"
        } else if isScheduled {
            return "checkmark.circle.fill"
        } else if program.hasEnded {
            return "clock"
        } else {
            return "record.circle"
        }
    }

    private var actionColor: Color {
        if existingRecording != nil {
            return Theme.accent
        } else if isScheduled {
            return Theme.success
        } else if program.hasEnded {
            return Theme.textTertiary
        } else {
            return Theme.accent
        }
    }

    private var isActionable: Bool {
        existingRecording != nil || !program.hasEnded
    }

    var body: some View {
        Button {
            performAction()
        } label: {
            HStack(alignment: .center, spacing: Theme.spacingLG) {
                // Sport icon or default TV icon
                ZStack {
                    Circle()
                        .fill(Theme.surfaceElevated)

                    if let sport = SportDetector.detect(from: program) {
                        Image(systemName: sport.sfSymbol)
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 80, height: 80)

                // Program info
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    // Live indicator (if currently airing)
                    if program.isCurrentlyAiring {
                        Label("Live", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }

                    // Program title
                    Text(program.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let subtitle = program.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    // Channel and time info
                    HStack(spacing: Theme.spacingMD) {
                        Label(channel.name, systemImage: "tv")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)

                        Label {
                            Text("\(program.startDate, style: .date) at \(program.startDate, style: .time)")
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    }

                    // Already scheduled info (if another airing is scheduled)
                    if let earlier = earlierScheduled {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.checkmark")
                            Text("Already scheduled at \(earlier.startDate ?? Date(), style: .time) on \(earlier.startDate ?? Date(), style: .date)")
                        }
                        .font(.caption2)
                        .foregroundStyle(Theme.success)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Action label on the right
                HStack(spacing: 8) {
                    if isProcessing {
                        ProgressView()
                    } else {
                        Image(systemName: actionIcon)
                        Text(actionLabel)
                    }
                }
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(actionColor)
                .padding(.horizontal, Theme.spacingLG)
                .padding(.vertical, Theme.spacingMD)
            }
            .padding()
        }
        .buttonStyle(.card)
        .contextMenu {
            Button {
                onShowDetails?()
            } label: {
                Label("Details", systemImage: "info.circle")
            }
        }
        .disabled(!isActionable || isProcessing)
        .task {
            await checkIfScheduled()
        }
    }

    private func performAction() {
        if let existing = existingRecording {
            playExistingRecording(existing)
        } else if !program.hasEnded {
            toggleRecording()
        }
    }

    private func namesAreEqual(_ name1: String, _ name2: String) -> Bool {
        let n1 = name1.lowercased().trimmingCharacters(in: .whitespaces)
        let n2 = name2.lowercased().trimmingCharacters(in: .whitespaces)
        return n1 == n2
    }

    private func checkIfScheduled() async {
        do {
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            let allRecordings = completed + recording + scheduled

            if let recording = allRecordings.first(where: { $0.epgEventId == program.id }) {
                isScheduled = true
                existingRecordingId = recording.id
            }

            if let existing = completed.first(where: { recording in
                namesAreEqual(recording.name, program.name) && recording.recordingStatus == .ready
            }) {
                existingRecording = existing
            }

            if let earlier = scheduled.first(where: { recording in
                namesAreEqual(recording.name, program.name) &&
                recording.epgEventId != program.id &&
                (recording.startTime ?? 0) < program.start &&
                recording.recordingStatus == .pending
            }) {
                earlierScheduled = earlier
            }
        } catch {
            // Silently fail
        }
    }

    private func toggleRecording() {
        isProcessing = true
        Task {
            do {
                if isScheduled, let recordingId = existingRecordingId {
                    try await client.cancelRecording(recordingId: recordingId)
                    isScheduled = false
                    existingRecordingId = nil
                } else {
                    try await client.scheduleRecording(eventId: program.id)
                    isScheduled = true
                    await checkIfScheduled()
                }
                isProcessing = false
                onRecordingChanged?()
            } catch {
                isProcessing = false
            }
        }
    }

    private func playExistingRecording(_ recording: Recording) {
        Task {
            do {
                let url = try await client.recordingStreamURL(recordingId: recording.id)
                appState.playStream(
                    url: url,
                    title: recording.name,
                    recordingId: recording.id,
                    resumePosition: recording.playbackPosition
                )
            } catch {
                // Silently fail
            }
        }
    }
}
#endif

#Preview {
    List {
        TopicProgramRow(
            program: .preview,
            channel: Channel(id: 1, name: "ABC", number: 7),
            matchedKeyword: "Sports"
        )
        .listRowBackground(Theme.surface)
    }
    .listStyle(.plain)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
