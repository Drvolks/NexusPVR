//
//  RecordingRow.swift
//  nextpvr-apple-client
//
//  Recording list row
//

import SwiftUI

// MARK: - Recording Progress Bar

struct RecordingProgressBar: View {
    let progress: Double // 0.0 to 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.textTertiary.opacity(0.2))

                Capsule()
                    .fill(Theme.recording)
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Watch Progress Circle

struct WatchProgressCircle: View {
    let progress: Double // 0.0 to 1.0
    let size: CGFloat
    var sport: Sport? = nil

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

            // Center icon: sport icon if available, otherwise play/checkmark
            if let sport {
                Image(systemName: sport.sfSymbol)
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(isFullyWatched ? Theme.success : Theme.accent)
            } else if isFullyWatched {
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

private func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 && minutes > 0 {
        return "\(hours)h \(minutes)m"
    } else if hours > 0 {
        return "\(hours)h"
    } else if minutes > 0 {
        return "\(minutes)m"
    } else {
        return "\(seconds)s"
    }
}

/// Determines if the file size suggests a complete recording (timestamp issue)
/// or a truncated file, and returns the appropriate warning label.
@ViewBuilder
private func durationWarningLabel(recording: Recording, mismatch: (expected: Int, detected: Int)) -> some View {
    // Check if file size is reasonable for the expected duration
    // 0.2 MB/s (1.6 Mbps) is a very conservative minimum for any video
    let fileSeemsComplete: Bool = {
        guard let size = recording.size, mismatch.expected > 0 else { return false }
        let bytesPerSecond = Double(size) / Double(mismatch.expected)
        return bytesPerSecond >= 200_000
    }()

    if fileSeemsComplete {
        Label {
            Text("Detected stream duration \(formatDuration(mismatch.detected)), playback may be impacted")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(Theme.warning)
    } else {
        Label {
            Text("Duration mismatch: expected \(formatDuration(mismatch.expected)), detected \(formatDuration(mismatch.detected))")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(Theme.warning)
    }
}

struct RecordingRow: View {
    let recording: Recording
    var durationMismatch: (expected: Int, detected: Int)?
    var durationVerified: Bool = false

    private var watchProgress: Double? {
        guard let position = recording.playbackPosition,
              let duration = recording.duration,
              duration > 0,
              position > 0 else {
            return nil
        }
        return min(1.0, Double(position) / Double(duration))
    }

    private var detectedSport: Sport? {
        SportDetector.detect(from: recording)
    }

    private func recordingProgress(at date: Date) -> Double? {
        guard recording.recordingStatus == .recording,
              let recordingStart = recording.recordingStartTime,
              let totalDuration = recording.totalRecordingDuration,
              totalDuration > 0 else { return nil }
        let elapsed = date.timeIntervalSince1970 - Double(recordingStart)
        return min(max(elapsed / Double(totalDuration), 0), 1)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spacingMD) {
            // Left column: Status indicator (centered vertically)
            statusIcon

            // Content area
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                // Row 1: Program title
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

                // Row 3: Date + time range | Duration
                HStack {
                    if let start = recording.startDate {
                        if let end = recording.endDate {
                            Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            Text(start.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer()
                    if let duration = recording.durationMinutes {
                        Text("\(duration) min")
                            .font(.caption)
                            .foregroundStyle(durationVerified ? Theme.success : Theme.textTertiary)
                    }
                }

                // Row 4: Duration mismatch warning
                if let mismatch = durationMismatch {
                    durationWarningLabel(recording: recording, mismatch: mismatch)
                }

                // Row 5: Recording progress bar
                if recording.recordingStatus == .recording {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let progress = recordingProgress(at: context.date) {
                            RecordingProgressBar(progress: progress)
                        }
                    }
                }
            }
        }
        .padding(.vertical, Theme.spacingSM)
        .accessibilityIdentifier("recording-row-\(recording.id)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        // For completed recordings with watch progress, show the progress circle
        if recording.recordingStatus.isCompleted, let progress = watchProgress {
            WatchProgressCircle(progress: progress, size: 44, sport: detectedSport)
        } else if recording.recordingStatus.isCompleted {
            // Completed but not started watching
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.2))
                    .frame(width: 44, height: 44)

                Image(systemName: detectedSport?.sfSymbol ?? "play.fill")
                    .font(.system(size: 44 * 0.38))
                    .foregroundStyle(Theme.accent)
            }
        } else {
            // Other statuses (pending, recording, failed, etc.)
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 44, height: 44)

                Image(systemName: detectedSport?.sfSymbol ?? statusIconName)
                    .font(.system(size: 44 * 0.38))
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
    var durationMismatch: (expected: Int, detected: Int)?
    var durationVerified: Bool = false

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

    private var detectedSport: Sport? {
        SportDetector.detect(from: recording)
    }

    private func recordingProgress(at date: Date) -> Double? {
        guard recording.recordingStatus == .recording,
              let recordingStart = recording.recordingStartTime,
              let totalDuration = recording.totalRecordingDuration,
              totalDuration > 0 else { return nil }
        let elapsed = date.timeIntervalSince1970 - Double(recordingStart)
        return min(max(elapsed / Double(totalDuration), 0), 1)
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
            if recording.recordingStatus.isPlayable {
                onPlay()
            } else {
                onShowDetails()
            }
        } label: {
            HStack(spacing: Theme.spacingLG) {
                // Status icon or watch progress (with sport icon merged in center)
                if recording.recordingStatus.isCompleted, let progress = watchProgress {
                    WatchProgressCircle(progress: progress, size: 60, sport: detectedSport)
                } else {
                    ZStack {
                        Circle()
                            .fill(actionColor.opacity(0.2))
                            .frame(width: 60, height: 60)

                        Image(systemName: detectedSport?.sfSymbol ?? actionIcon)
                            .font(.system(size: 60 * 0.38))
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

                        if let start = recording.startDate {
                            Label {
                                if let end = recording.endDate {
                                    Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                                } else {
                                    Text(start.formatted(date: .abbreviated, time: .shortened))
                                }
                            } icon: {
                                Image(systemName: "calendar")
                            }
                        }

                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)

                    // Recording progress bar
                    if recording.recordingStatus == .recording {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            if let progress = recordingProgress(at: context.date) {
                                RecordingProgressBar(progress: progress)
                            }
                        }
                    }

                    // Duration mismatch warning
                    if let mismatch = durationMismatch {
                        durationWarningLabel(recording: recording, mismatch: mismatch)
                    }
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

                    if let duration = recording.durationMinutes {
                        Text("\(duration) min")
                            .font(.caption)
                            .foregroundStyle(durationVerified ? Theme.success : Theme.textTertiary)
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
