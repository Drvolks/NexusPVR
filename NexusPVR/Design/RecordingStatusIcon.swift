//
//  RecordingStatusIcon.swift
//  NexusPVR
//
//  Reusable recording status icon with watch progress, sport detection, and status indicators
//

import SwiftUI

struct RecordingStatusIcon: View {
    let recording: Recording
    var size: CGFloat = 44

    private var watchProgress: Double? {
        guard let position = recording.playbackPosition,
              let duration = recording.duration,
              duration > 0, position > 0 else { return nil }
        return min(1.0, Double(position) / Double(duration))
    }

    private var sport: Sport? {
        SportDetector.detect(from: recording)
    }

    var body: some View {
        if recording.recordingStatus.isCompleted, let progress = watchProgress {
            WatchProgressCircle(progress: progress, size: size, sport: sport)
        } else if recording.recordingStatus.isCompleted {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.2))
                    .frame(width: size, height: size)
                Image(systemName: sport?.sfSymbol ?? "play.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundColor(Theme.accent)
            }
        } else {
            let color = recording.recordingStatus.statusColor
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: size, height: size)
                Image(systemName: sport?.sfSymbol ?? recording.recordingStatus.statusIcon)
                    .font(.system(size: size * 0.38))
                    .foregroundColor(color)
            }
        }
    }
}
