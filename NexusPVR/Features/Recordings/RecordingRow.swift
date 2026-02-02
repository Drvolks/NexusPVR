//
//  RecordingRow.swift
//  nextpvr-apple-client
//
//  Recording list row
//

import SwiftUI

// MARK: - Watch Progress Circle

struct WatchProgressCircle: View {
    let progress: Double // 0.0 to 1.0
    let size: CGFloat

    private var isFullyWatched: Bool {
        progress >= 0.9
    }

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Theme.textTertiary.opacity(0.3), lineWidth: size * 0.12)

            // Progress arc
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    isFullyWatched ? Theme.success : Theme.accent,
                    style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            // Center icon
            if isFullyWatched {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Theme.success)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(Theme.accent)
                    .offset(x: size * 0.04) // Slight offset to center play icon visually
            }
        }
        .frame(width: size, height: size)
    }
}

struct RecordingRow: View {
    let recording: Recording

    private var watchProgress: Double? {
        guard let position = recording.playbackPosition,
              let duration = recording.duration,
              duration > 0,
              position > 0 else {
            return nil
        }
        return min(1.0, Double(position) / Double(duration))
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spacingMD) {
            // Left column: Status indicator (centered vertically)
            statusIcon

            // Content area
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                // Row 1: Program title (full width)
                Text(recording.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                // Row 2: Channel name | File size
                HStack {
                    if let channel = recording.channel {
                        Text(channel)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let size = recording.fileSizeFormatted {
                        Text(size)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                // Row 3: Date | Duration
                HStack {
                    if let date = recording.startDate {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if let duration = recording.durationMinutes {
                        Text("\(duration) min")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .padding(.vertical, Theme.spacingSM)
    }

    @ViewBuilder
    private var statusIcon: some View {
        // For completed recordings with watch progress, show the progress circle
        if recording.recordingStatus.isCompleted, let progress = watchProgress {
            WatchProgressCircle(progress: progress, size: 44)
        } else if recording.recordingStatus.isCompleted {
            // Completed but not started watching - show play icon
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.2))
                    .frame(width: 44, height: 44)

                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
        } else {
            // Other statuses (pending, recording, failed, etc.)
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 44, height: 44)

                Image(systemName: statusIconName)
                    .font(.title3)
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusIconName: String {
        switch recording.recordingStatus {
        case .pending:
            return "clock"
        case .recording:
            return "record.circle"
        case .ready:
            return "checkmark.circle"
        case .failed:
            return "xmark.circle"
        case .conflict:
            return "exclamationmark.triangle"
        case .deleted:
            return "trash"
        }
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
}

// MARK: - tvOS Version

#if os(tvOS)
struct RecordingRowTV: View {
    let recording: Recording
    let onPlay: () -> Void
    let onShowDetails: () -> Void
    let onDelete: () -> Void

    private var watchProgress: Double? {
        guard let position = recording.playbackPosition,
              let duration = recording.duration,
              duration > 0,
              position > 0 else {
            return nil
        }
        return min(1.0, Double(position) / Double(duration))
    }

    private var actionLabel: String {
        if recording.recordingStatus == .ready, let progress = watchProgress {
            if progress >= 0.9 {
                return "Watched"
            } else {
                return "Resume"
            }
        }

        switch recording.recordingStatus {
        case .ready:
            return "Play"
        case .recording:
            return "Recording..."
        case .pending:
            return "Scheduled"
        case .failed:
            return "Failed"
        case .conflict:
            return "Conflict"
        case .deleted:
            return "Deleted"
        }
    }

    private var actionIcon: String {
        switch recording.recordingStatus {
        case .ready:
            return "play.circle.fill"
        case .recording:
            return "record.circle"
        case .pending:
            return "clock"
        case .failed:
            return "xmark.circle"
        case .conflict:
            return "exclamationmark.triangle"
        case .deleted:
            return "trash"
        }
    }

    private var actionColor: Color {
        switch recording.recordingStatus {
        case .ready:
            return Theme.accent
        case .recording:
            return Theme.recording
        case .pending:
            return Theme.warning
        case .failed, .deleted:
            return Theme.error
        case .conflict:
            return Theme.warning
        }
    }

    var body: some View {
        Button {
            if recording.recordingStatus.isCompleted {
                onPlay()
            } else {
                onShowDetails()
            }
        } label: {
            HStack(spacing: Theme.spacingLG) {
                // Status icon or watch progress
                if recording.recordingStatus.isCompleted, let progress = watchProgress {
                    WatchProgressCircle(progress: progress, size: 60)
                } else {
                    ZStack {
                        Circle()
                            .fill(actionColor.opacity(0.2))
                            .frame(width: 60, height: 60)

                        Image(systemName: actionIcon)
                            .font(.title2)
                            .foregroundStyle(actionColor)
                    }
                }

                // Recording info
                VStack(alignment: .leading, spacing: Theme.spacingXS) {
                    Text(recording.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let subtitle = recording.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: Theme.spacingMD) {
                        if let channel = recording.channel {
                            Label(channel, systemImage: "tv")
                        }

                        if let date = recording.startDate {
                            Label {
                                Text(date, style: .date)
                            } icon: {
                                Image(systemName: "calendar")
                            }
                        }

                        if let duration = recording.durationMinutes {
                            Label("\(duration) min", systemImage: "clock")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                // Right side info
                VStack(alignment: .trailing, spacing: Theme.spacingXS) {
                    if !recording.recordingStatus.isCompleted {
                        Text(actionLabel)
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundStyle(actionColor)
                    }

                    if let size = recording.fileSizeFormatted {
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, Theme.spacingMD)
            }
            .padding()
        }
        .buttonStyle(.card)
    }
}
#endif

#Preview {
    List {
        RecordingRow(recording: .preview)
        RecordingRow(recording: .scheduledPreview)
    }
    .listStyle(.plain)
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
