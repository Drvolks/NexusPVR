//
//  TopicProgramRow.swift
//  nextpvr-apple-client
//
//  Row displaying a program matching a topic keyword
//

import SwiftUI

private func normalizeProgramName(_ name: String) -> String {
    name
        .replacingOccurrences(of: " ᴺᵉʷ", with: "")
        .lowercased()
        .split(separator: " ")
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
}

private func programNamesAreEqual(_ name1: String, _ name2: String) -> Bool {
    normalizeProgramName(name1) == normalizeProgramName(name2)
}

struct TopicProgramRow: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState

    let program: Program
    let channel: Channel
    let matchedKeyword: String
    var onRecordingChanged: (() -> Void)? = nil
    var onShowDetails: ((Int?, Recording?) -> Void)? = nil

    @State private var isScheduled = false
    @State private var isRecording = false
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
                // Live indicator
                if program.isCurrentlyAiring {
                    Label("Live", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }

                // Row 1: Program title
                Text(program.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                // Row 2: Channel name | Action button
                HStack {
                    Text(channel.name)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    // Action button
                    if !program.hasEnded {
                        Button {
                            toggleRecording()
                        } label: {
                            HStack(spacing: 4) {
                                if isProcessing {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else if isRecording {
                                    Image(systemName: "record.circle")
                                        .foregroundStyle(Theme.recording)
                                    Text("Recording")
                                        .font(.caption)
                                        .foregroundStyle(Theme.recording)
                                } else if isScheduled {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.success)
                                    Text("Scheduled")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                        .accessibilityIdentifier("scheduled-indicator")
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
                            .background(isRecording ? Theme.recording.opacity(0.1) : isScheduled ? Theme.success.opacity(0.1) : Theme.accent.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessing)
                    }
                }

                // Row 3: Date | Already recorded / Earlier scheduled info
                HStack {
                    Text("\(program.startDate, style: .date) at \(program.startDate, style: .time)")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)

                    Spacer()

                    if let existing = existingRecording {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                            Text("Already recorded \(existing.startDate ?? Date(), style: .time)")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    } else if let earlier = earlierScheduled {
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
        .contentShape(Rectangle())
        .onTapGesture {
            onShowDetails?(existingRecordingId, existingRecording)
        }
        .task {
            await checkIfScheduled()
        }
    }


    private func checkIfScheduled() async {
        do {
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            let allRecordings = completed + recording + scheduled

            // Check if this exact program is scheduled or recording
            if let rec = allRecordings.first(where: { $0.epgEventId == program.id }) {
                isScheduled = true
                isRecording = rec.recordingStatus == .recording
                existingRecordingId = rec.id
            }

            // Check for existing completed recording with similar name (within 48h)
            let cutoff = Date().addingTimeInterval(-48 * 3600)
            if let existing = completed.first(where: { recording in
                programNamesAreEqual(recording.name, program.name) &&
                recording.recordingStatus == .ready &&
                (recording.startDate ?? .distantPast) > cutoff
            }) {
                existingRecording = existing
            }

            if let earlier = scheduled.first(where: { recording in
                programNamesAreEqual(recording.name, program.name) &&
                recording.epgEventId != program.id &&  // Exclude current program
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
    @State private var isRecording = false
    @State private var existingRecordingId: Int?
    @State private var isProcessing = false
    @State private var existingRecording: Recording?
    @State private var earlierScheduled: Recording?

    private var actionLabel: String {
        if isRecording {
            return "Recording"
        } else if isScheduled {
            return "Scheduled"
        } else if program.hasEnded {
            return existingRecording != nil ? "Watch Recording" : "Ended"
        } else {
            return "Record"
        }
    }

    private var actionIcon: String {
        if isRecording {
            return "record.circle"
        } else if isScheduled {
            return "checkmark.circle.fill"
        } else if program.hasEnded {
            return existingRecording != nil ? "play.circle.fill" : "clock"
        } else {
            return "record.circle"
        }
    }

    private var actionColor: Color {
        if isRecording {
            return Theme.recording
        } else if isScheduled {
            return Theme.success
        } else if program.hasEnded {
            return existingRecording != nil ? Theme.accent : Theme.textTertiary
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

                    // Already recorded info (prioritized over already scheduled)
                    if let existing = existingRecording {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                            Text("Already recorded \(existing.startDate ?? Date(), style: .time)")
                        }
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                    } else if let earlier = earlierScheduled {
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
        if !program.hasEnded {
            toggleRecording()
        } else if let existing = existingRecording {
            playExistingRecording(existing)
        }
    }


    private func checkIfScheduled() async {
        do {
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            let allRecordings = completed + recording + scheduled

            if let rec = allRecordings.first(where: { $0.epgEventId == program.id }) {
                isScheduled = true
                isRecording = rec.recordingStatus == .recording
                existingRecordingId = rec.id
            }

            if let existing = completed.first(where: { recording in
                programNamesAreEqual(recording.name, program.name) && recording.recordingStatus == .ready
            }) {
                existingRecording = existing
            }

            if let earlier = scheduled.first(where: { recording in
                programNamesAreEqual(recording.name, program.name) &&
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
