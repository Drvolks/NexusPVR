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
        #if !os(tvOS)
        .onTapGesture {
            onShowDetails?(vm.existingRecordingId, vm.existingRecording)
        }
        #endif
        .task {
            if appState.userLevel >= 1 {
                await vm.checkIfScheduled(using: client)
            }
        }
    }
}

// MARK: - tvOS Row

#if os(tvOS)
private struct TVTopicSubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVTopicFocusWrapper {
            configuration.label
        }
    }
}

private struct TVTopicFocusWrapper<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isFocused ? Theme.accent.opacity(0.8) : Color.clear, lineWidth: 1.5)
            )
            .shadow(color: isFocused ? .black.opacity(0.28) : .clear, radius: 7, x: 0, y: 2)
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.14), value: isFocused)
            .modifier(TVFocusEffectDisabledCompat())
    }
}

private struct TVFocusEffectDisabledCompat: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 17.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

struct TopicProgramRowTV: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    @Environment(\.isFocused) private var isFocused

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

    private var rightCellBackground: Color {
        Theme.guideNowPlaying
    }

    var body: some View {
        Button {
            guard !vm.isProcessing else { return }
            if canRecord && !program.hasEnded {
                vm.toggleRecording(using: client, onChanged: onRecordingChanged)
            } else {
                onShowDetails?()
            }
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    CachedAsyncImage(url: try? client.channelIconURL(channelId: channel.id)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Image(systemName: "tv")
                            .font(.title2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, Theme.spacingMD)
                .frame(width: Theme.channelColumnWidth, height: Theme.cellHeight)

                ZStack {
                    HStack(spacing: 10) {
                        ProgramSportIcon(program: program, size: 54, iconSize: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(program.cleanName)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white.opacity(isFocused ? 1.0 : 0.95))
                                .lineLimit(1)

                            Text(vm.programScheduleText)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(.white.opacity(isFocused ? 0.82 : 0.72))
                                .lineLimit(1)

                            if let subtitle = program.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 17))
                                    .foregroundStyle(.white.opacity(isFocused ? 0.76 : 0.64))
                                    .lineLimit(1)
                            }

                            if let existing = vm.existingRecording {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle")
                                    Text("Already recorded \(existing.startDate ?? Date(), style: .time)")
                                }
                                .font(.caption2)
                                .foregroundStyle(Theme.warning.opacity(0.95))
                            } else if let earlier = vm.earlierScheduled {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock.badge.checkmark")
                                    Text("Already scheduled at \(earlier.startDate ?? Date(), style: .time)")
                                }
                                .font(.caption2)
                                .foregroundStyle(Theme.success.opacity(0.9))
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
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(actionColor.opacity(0.95))
                        .padding(.horizontal, Theme.spacingLG)
                        .padding(.vertical, Theme.spacingMD)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    if program.isNew {
                        VStack {
                            HStack {
                                Spacer()
                                Theme.success
                                    .frame(width: 8, height: 24)
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    )
                            }
                            Spacer()
                        }
                    }
                }
                .frame(height: Theme.cellHeight)
                .background(RoundedRectangle(cornerRadius: 12).fill(rightCellBackground))
            }
        }
        .buttonStyle(TVTopicSubtleButtonStyle())
        .contextMenu {
            Button {
                onShowDetails?()
            } label: {
                Label("Details", systemImage: "info.circle")
            }
        }
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
