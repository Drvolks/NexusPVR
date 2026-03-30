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

@ViewBuilder
private func durationUnverifiableLabel() -> some View {
    Label {
        Text("Duration could not be verified for this stream, playback may be impacted")
    } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
    }
    .font(.caption)
    .foregroundStyle(Theme.warning)
}

struct RecordingRow: View {
    let recording: Recording
    var showSeriesMeta: Bool = false
    var showSeriesDescriptionOneLine: Bool = false
    var hideSeriesChannelName: Bool = false
    var durationMismatch: (expected: Int, detected: Int)?
    var durationVerified: Bool = false
    var durationUnverifiable: Bool = false
    
    private var usesUnifiedMetadataLayout: Bool {
        recording.recordingStatus.isScheduled || recording.recordingStatus.isCompleted
    }

    private var cleanedEpisodeTitle: String? {
        guard let subtitle = recording.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty else { return nil }
        let cleaned = SeriesInfo.stripPattern(from: subtitle).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private var primaryTitleText: String {
        if let episode = cleanedEpisodeTitle {
            return "\(recording.cleanName) - \(episode)"
        }
        return recording.cleanName
    }

    private var broadcastDateTimeText: String? {
        guard let start = recording.startDate else { return nil }
        if let end = recording.endDate {
            return "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return start.formatted(date: .abbreviated, time: .shortened)
    }

    private var oneLineDescriptionText: String? {
        guard let desc = recording.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
              !desc.isEmpty else { return nil }
        return desc
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
                if usesUnifiedMetadataLayout {
                    // Row 1: SxxExx Program - Episode
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if showSeriesMeta, let series = recording.seriesInfo {
                            Text(series.shortDisplayString)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }

                        Text(primaryTitleText)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if recording.isNew { NewBadge() }
                    }

                    // Row 2: Date/time | Duration (right unchanged)
                    HStack {
                        if let dateTime = broadcastDateTimeText {
                            Text(dateTime)
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let duration = recording.durationMinutes {
                            Text("\(duration) min")
                                .font(.caption)
                                .foregroundStyle(durationVerified ? Theme.success : Theme.textTertiary)
                        }
                    }

                    // Row 3: Description one-liner | Size (right unchanged)
                    HStack(alignment: .firstTextBaseline, spacing: Theme.spacingSM) {
                        if let desc = oneLineDescriptionText {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let size = recording.fileSizeFormatted {
                            Text(size)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    // Row 1: Program title
                    HStack(alignment: .top, spacing: 6) {
                        if showSeriesMeta, let series = recording.seriesInfo {
                            Text(series.shortDisplayString)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        }

                        Text(recording.cleanName)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Spacer()
                        if recording.isNew { NewBadge() }
                    }

                    if showSeriesDescriptionOneLine,
                       showSeriesMeta,
                       let desc = recording.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !desc.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.spacingSM) {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            if hideSeriesChannelName,
                               showSeriesMeta,
                               let size = recording.fileSizeFormatted {
                                Text(size)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    // Row 2: Channel name | File size
                    if (recording.channel != nil && !(hideSeriesChannelName && showSeriesMeta)) ||
                        (recording.fileSizeFormatted != nil && !(hideSeriesChannelName && showSeriesMeta)) {
                        HStack {
                            if !(hideSeriesChannelName && showSeriesMeta),
                               let channel = recording.channel {
                                Text(channel)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if !(hideSeriesChannelName && showSeriesMeta),
                               let size = recording.fileSizeFormatted {
                                Text(size)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }
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
                }

                // Row 4: Duration mismatch warning
                if let mismatch = durationMismatch {
                    durationWarningLabel(recording: recording, mismatch: mismatch)
                } else if durationUnverifiable {
                    durationUnverifiableLabel()
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

    private var statusIcon: some View {
        RecordingStatusIcon(recording: recording, size: 44)
    }
}

// MARK: - tvOS Version

#if os(tvOS)
struct TVRecordingSubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVRecordingFocusWrapper {
            configuration.label
        }
    }
}

private struct TVRecordingFocusWrapper<Content: View>: View {
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
            .focusEffectDisabled()
    }
}

struct RecordingRowTV: View {
    @EnvironmentObject private var client: PVRClient
    @Environment(\.isFocused) private var isFocused

    let recording: Recording
    let fallbackChannelId: Int?
    let onPlay: () -> Void
    let onShowDetails: () -> Void
    let onDelete: () -> Void
    var showSeriesMeta: Bool = false
    var durationMismatch: (expected: Int, detected: Int)?
    var durationVerified: Bool = false
    var durationUnverifiable: Bool = false
    private static let seriesDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
    private static let seriesTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var usesUnifiedMetadataLayout: Bool {
        recording.recordingStatus.isScheduled || recording.recordingStatus.isCompleted
    }

    private var cleanedEpisodeTitle: String? {
        guard let subtitle = recording.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty else { return nil }
        let cleaned = SeriesInfo.stripPattern(from: subtitle).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private var primaryTitleText: String {
        if let episode = cleanedEpisodeTitle {
            return "\(recording.cleanName) - \(episode)"
        }
        return recording.cleanName
    }

    private var broadcastDateTimeRangeText: String {
        guard let start = recording.startDate else { return "No schedule" }
        let dateText = Self.seriesDateFormatter.string(from: start)
        let startText = Self.seriesTimeFormatter.string(from: start)
        if let end = recording.endDate {
            let endText = Self.seriesTimeFormatter.string(from: end)
            return "\(dateText) - \(startText) - \(endText)"
        }
        return "\(dateText) - \(startText)"
    }

    private var oneLineDescriptionText: String? {
        guard let desc = recording.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
              !desc.isEmpty else { return nil }
        return desc
    }

    private var watchProgress: Double? {
        guard let position = recording.playbackPosition,
              let duration = recording.duration,
              duration > 0, position > 0 else { return nil }
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

    private func recordingProgress(at date: Date) -> Double? {
        guard recording.recordingStatus == .recording,
              let recordingStart = recording.recordingStartTime,
              let totalDuration = recording.totalRecordingDuration,
              totalDuration > 0 else { return nil }
        let elapsed = date.timeIntervalSince1970 - Double(recordingStart)
        return min(max(elapsed / Double(totalDuration), 0), 1)
    }

    private var timeRangeText: String {
        guard let start = recording.startDate else { return "No schedule" }
        if let end = recording.endDate {
            return "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
        }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private var seriesDateTimeRangeText: String {
        guard let start = recording.startDate else { return "No schedule" }
        let dateText = Self.seriesDateFormatter.string(from: start)
        let startText = Self.seriesTimeFormatter.string(from: start)
        if let end = recording.endDate {
            let endText = Self.seriesTimeFormatter.string(from: end)
            return "\(dateText) - \(startText) - \(endText)"
        }
        return "\(dateText) - \(startText)"
    }

    private var rightCellBackground: Color {
        if isFocused { return Theme.guideNowPlaying.opacity(0.9) }
        return Theme.guideNowPlaying
    }

    private var channelCellBackground: Color {
        usesUnifiedMetadataLayout ? Theme.surfaceElevated.opacity(0.9) : Color.clear
    }

    private var rowHeight: CGFloat {
        if usesUnifiedMetadataLayout, oneLineDescriptionText != nil {
            return Theme.cellHeight + 14
        }
        if showSeriesMeta, seriesDescriptionText != nil {
            return Theme.cellHeight + 20
        }
        return Theme.cellHeight
    }

    private var scheduledDetailText: String? {
        guard recording.recordingStatus.isScheduled else { return nil }
        if let subtitle = recording.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subtitle.isEmpty {
            return subtitle
        }
        if let desc = recording.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty {
            return desc
        }
        return nil
    }

    private var effectiveChannelId: Int? {
        recording.channelId ?? fallbackChannelId
    }

    private var tvDurationWarningText: String? {
        if let mismatch = durationMismatch {
            let fileSeemsComplete: Bool = {
                guard let size = recording.size, mismatch.expected > 0 else { return false }
                let bytesPerSecond = Double(size) / Double(mismatch.expected)
                return bytesPerSecond >= 200_000
            }()
            if fileSeemsComplete {
                return "Detected stream duration \(formatDuration(mismatch.detected)), playback may be impacted"
            } else {
                return "Duration mismatch: expected \(formatDuration(mismatch.expected)), detected \(formatDuration(mismatch.detected))"
            }
        }
        if durationUnverifiable {
            return "Duration could not be verified for this stream, playback may be impacted"
        }
        return nil
    }

    private var seriesDescriptionText: String? {
        guard showSeriesMeta,
              let desc = recording.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
              !desc.isEmpty else { return nil }
        if let scheduled = scheduledDetailText, scheduled == desc {
            return nil
        }
        return desc
    }

    var body: some View {
        Button {
            if recording.recordingStatus.isPlayable {
                onPlay()
            } else {
                onShowDetails()
            }
        } label: {
            HStack(spacing: 10) {
                // Channel column (Guide-like left side)
                HStack(spacing: 10) {
                    if let channelId = effectiveChannelId {
                        CachedAsyncImage(url: try? client.channelIconURL(channelId: channelId)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Image(systemName: "tv")
                                .font(.title2)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    } else {
                        Image(systemName: "tv")
                            .font(.title2)
                            .foregroundStyle(Theme.textTertiary)
                        Text(recording.channel ?? "Channel")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Theme.spacingMD)
                .frame(width: Theme.channelColumnWidth, height: rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(channelCellBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isFocused ? Theme.accent.opacity(0.35) : Theme.surfaceHighlight.opacity(0.55),
                            lineWidth: 1
                        )
                )

                // Program cell (Guide-like right side)
                ZStack {
                    HStack(spacing: 10) {
                        RecordingStatusIcon(recording: recording, size: 54)

                        VStack(alignment: .leading, spacing: 4) {
                            if usesUnifiedMetadataLayout {
                                // Line 1: SxxExx Program - Episode
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if showSeriesMeta, let series = recording.seriesInfo {
                                        Text(series.shortDisplayString)
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(Theme.accent.opacity(isFocused ? 0.98 : 0.9))
                                            .lineLimit(1)
                                    }

                                    Text(primaryTitleText)
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary.opacity(isFocused ? 1.0 : 0.95))
                                        .lineLimit(1)
                                }

                                // Line 2: Broadcast date and time
                                Text(broadcastDateTimeRangeText)
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary.opacity(isFocused ? 0.88 : 0.76))
                                    .lineLimit(1)

                                // Line 3: Description one-liner
                                if let desc = oneLineDescriptionText {
                                    Text(desc)
                                        .font(.system(size: 17))
                                        .foregroundStyle(Theme.textSecondary.opacity(isFocused ? 0.84 : 0.72))
                                        .lineLimit(1)
                                }
                            } else {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if showSeriesMeta, let series = recording.seriesInfo {
                                        Text(series.shortDisplayString)
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(Theme.accent.opacity(isFocused ? 0.98 : 0.9))
                                            .lineLimit(1)
                                    }

                                    Text(recording.cleanName)
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary.opacity(isFocused ? 1.0 : 0.95))
                                        .lineLimit(1)
                                }

                                Text(showSeriesMeta ? seriesDateTimeRangeText : timeRangeText)
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary.opacity(isFocused ? 0.88 : 0.76))
                                    .lineLimit(1)

                                if let detail = scheduledDetailText {
                                    Text(detail)
                                        .font(.system(size: 17))
                                        .foregroundStyle(Theme.textSecondary.opacity(isFocused ? 0.84 : 0.72))
                                        .lineLimit(1)
                                }

                                if let desc = seriesDescriptionText {
                                    Text(desc)
                                        .font(.system(size: 16))
                                        .foregroundStyle(Theme.textTertiary.opacity(isFocused ? 0.9 : 0.78))
                                        .lineLimit(2)
                                }
                            }

                            if let warning = tvDurationWarningText {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text(warning)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                                .foregroundStyle(Theme.warning.opacity(isFocused ? 0.95 : 0.88))
                            }

                            if recording.recordingStatus == .recording {
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    if let progress = recordingProgress(at: context.date) {
                                        RecordingProgressBar(progress: progress)
                                            .frame(maxWidth: 360)
                                    }
                                }
                            }
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .trailing, spacing: 4) {
                            if !recording.recordingStatus.isCompleted {
                                Text(actionLabel)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(
                                        isFocused
                                            ? Theme.textPrimary.opacity(0.92)
                                            : recording.recordingStatus.statusColor.opacity(0.9)
                                    )
                            }
                            if let size = recording.fileSizeFormatted {
                                Text(size)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary.opacity(isFocused ? 0.75 : 0.62))
                            }
                            if let duration = recording.durationMinutes {
                                Text("\(duration) min")
                                    .font(.caption)
                                    .foregroundStyle(
                                        durationVerified
                                            ? Theme.success.opacity(isFocused ? 0.9 : 0.75)
                                            : Theme.textTertiary.opacity(isFocused ? 0.72 : 0.58)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    if recording.isNew {
                        VStack {
                            HStack {
                                Spacer()
                                Theme.success
                                    .frame(width: 8, height: 24)
                                    .clipShape(UnevenRoundedRectangle(
                                        topLeadingRadius: 0,
                                        bottomLeadingRadius: 4,
                                        bottomTrailingRadius: 0,
                                        topTrailingRadius: 10
                                    ))
                            }
                            Spacer()
                        }
                    }
                }
                .frame(height: rowHeight)
                .background(RoundedRectangle(cornerRadius: 12).fill(rightCellBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFocused ? Theme.accent.opacity(0.75) : Color.clear, lineWidth: 1.5)
                )
                .shadow(color: isFocused ? .black.opacity(0.22) : .clear, radius: 6, x: 0, y: 2)
                .scaleEffect(isFocused ? 1.005 : 1.0, anchor: .leading)
                .animation(.easeInOut(duration: 0.14), value: isFocused)
            }
        }
        .buttonStyle(TVRecordingSubtleButtonStyle())
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
