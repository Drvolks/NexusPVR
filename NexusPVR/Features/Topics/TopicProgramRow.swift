//
//  TopicProgramRow.swift
//  nextpvr-apple-client
//
//  Row displaying a program matching a topic keyword
//

import SwiftUI

// MARK: - Shared Sport Icon View

struct ProgramSportIcon: View {
    let program: Program
    var size: CGFloat = 56
    var iconSize: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.surfaceElevated)

            if let sport = SportDetector.detect(from: program) {
                Image(systemName: sport.sfSymbol)
                    .font(.system(size: iconSize))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Image(systemName: "tv")
                    .font(.system(size: iconSize))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Recording Status Badge

struct RecordingStatusBadge: View {
    let isProcessing: Bool
    let isRecording: Bool
    let isScheduled: Bool

    var body: some View {
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
}

// MARK: - Existing Recording Info

struct ExistingRecordingInfo: View {
    let existingRecording: Recording?
    let earlierScheduled: Recording?

    var body: some View {
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

// MARK: - iOS/macOS Row

struct TopicProgramRow: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState

    let program: Program
    let channel: Channel
    let matchedKeyword: String
    var onRecordingChanged: (() -> Void)? = nil
    var onShowDetails: ((Int?, Recording?) -> Void)? = nil

    @StateObject private var vm: TopicProgramRowViewModel

    init(program: Program, channel: Channel, matchedKeyword: String,
         onRecordingChanged: (() -> Void)? = nil,
         onShowDetails: ((Int?, Recording?) -> Void)? = nil) {
        self.program = program
        self.channel = channel
        self.matchedKeyword = matchedKeyword
        self.onRecordingChanged = onRecordingChanged
        self.onShowDetails = onShowDetails
        _vm = StateObject(wrappedValue: TopicProgramRowViewModel(program: program, channel: channel))
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spacingMD) {
            ProgramSportIcon(program: program)

            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                if program.isCurrentlyAiring {
                    Label("Live", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }

                HStack(alignment: .top, spacing: 6) {
                    Text(program.cleanName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer()
                    if program.isNew { NewBadge() }
                }

                HStack {
                    Text(channel.name)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    if !program.hasEnded && appState.userLevel >= 1 {
                        Button {
                            vm.toggleRecording(using: client, onChanged: onRecordingChanged)
                        } label: {
                            RecordingStatusBadge(
                                isProcessing: vm.isProcessing,
                                isRecording: vm.isRecording,
                                isScheduled: vm.isScheduled
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isProcessing)
                    }
                }

                HStack {
                    Text(vm.programScheduleText)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)

                    Spacer()

                    ExistingRecordingInfo(
                        existingRecording: vm.existingRecording,
                        earlierScheduled: vm.earlierScheduled
                    )
                }
            }
        }
        .padding(.vertical, Theme.spacingSM)
        .contentShape(Rectangle())
        .accessibilityIdentifier("topic-program-\(program.id)")
        .onTapGesture {
            onShowDetails?(vm.existingRecordingId, vm.existingRecording)
        }
        .task {
            if appState.userLevel >= 1 {
                await vm.checkIfScheduled(using: client)
            }
        }
    }
}

// MARK: - tvOS Row

#if os(tvOS)
struct TopicProgramRowTV: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState

    let program: Program
    let channel: Channel
    let matchedKeyword: String
    var onRecordingChanged: (() -> Void)? = nil
    var onShowDetails: (() -> Void)? = nil

    @StateObject private var vm: TopicProgramRowViewModel

    init(program: Program, channel: Channel, matchedKeyword: String,
         onRecordingChanged: (() -> Void)? = nil,
         onShowDetails: (() -> Void)? = nil) {
        self.program = program
        self.channel = channel
        self.matchedKeyword = matchedKeyword
        self.onRecordingChanged = onRecordingChanged
        self.onShowDetails = onShowDetails
        _vm = StateObject(wrappedValue: TopicProgramRowViewModel(program: program, channel: channel))
    }

    private var canRecord: Bool { appState.userLevel >= 1 }

    private var actionLabel: String {
        if !canRecord {
            return program.isCurrentlyAiring ? "Watch" : "Details"
        } else if vm.isRecording {
            return "Recording"
        } else if vm.isScheduled {
            return "Scheduled"
        } else if program.hasEnded {
            return vm.existingRecording != nil ? "Watch Recording" : "Ended"
        } else {
            return "Record"
        }
    }

    private var actionIcon: String {
        if !canRecord {
            return program.isCurrentlyAiring ? "play.circle.fill" : "info.circle"
        } else if vm.isRecording {
            return "record.circle"
        } else if vm.isScheduled {
            return "checkmark.circle.fill"
        } else if program.hasEnded {
            return vm.existingRecording != nil ? "play.circle.fill" : "clock"
        } else {
            return "record.circle"
        }
    }

    private var actionColor: Color {
        if !canRecord {
            return Theme.accent
        } else if vm.isRecording {
            return Theme.recording
        } else if vm.isScheduled {
            return Theme.success
        } else if program.hasEnded {
            return vm.existingRecording != nil ? Theme.accent : Theme.textTertiary
        } else {
            return Theme.accent
        }
    }

    var body: some View {
        Button {
            onShowDetails?()
        } label: {
            HStack(alignment: .center, spacing: Theme.spacingLG) {
                ProgramSportIcon(program: program, size: 80, iconSize: 32)

                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    if program.isCurrentlyAiring {
                        Label("Live", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }

                    Text(program.cleanName)
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

                    HStack(spacing: Theme.spacingMD) {
                        Label(channel.name, systemImage: "tv")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)

                        Label {
                            Text(vm.programScheduleText)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)

                        if program.isNew { NewBadge() }
                    }

                    if let existing = vm.existingRecording {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                            Text("Already recorded \(existing.startDate ?? Date(), style: .time)")
                        }
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                    } else if let earlier = vm.earlierScheduled {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.checkmark")
                            Text("Already scheduled at \(earlier.startDate ?? Date(), style: .time) on \(earlier.startDate ?? Date(), style: .date)")
                        }
                        .font(.caption2)
                        .foregroundStyle(Theme.success)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if vm.isProcessing {
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
        .disabled(vm.isProcessing)
        .accessibilityIdentifier("topic-program-\(program.id)")
        .task {
            await vm.checkIfScheduled(using: client)
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
