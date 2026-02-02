//
//  ProgramCell.swift
//  nextpvr-apple-client
//
//  Individual program cell in the EPG grid
//

import SwiftUI

struct ProgramCell: View {
    let program: Program
    let width: CGFloat
    var isScheduledRecording: Bool = false
    var isCurrentlyRecording: Bool = false
    var matchesKeyword: Bool = false
    var leadingPadding: CGFloat = 0 // Padding for portion that's off-screen to the left

    var body: some View {
        ZStack(alignment: .leading) {
            // Background
            backgroundView

            // Content - padded to align with visible portion
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isCurrentlyRecording {
                        Image(systemName: "record.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.recording)
                    } else if isScheduledRecording {
                        Image(systemName: "record.circle")
                            .font(.caption2)
                            .foregroundStyle(Theme.recording)
                    }

                    Text(program.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }

                if let subtitle = program.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                Text(timeString)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.leading, Theme.spacingSM + (program.isCurrentlyAiring ? leadingPadding : 0))
            .padding(.trailing, Theme.spacingSM)
            .padding(.vertical, Theme.spacingXS)

            // Progress indicator for currently airing
            if program.isCurrentlyAiring {
                progressOverlay
            }
        }
        .frame(width: width, height: Theme.cellHeight - 2)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        .overlay {
            if matchesKeyword {
                RoundedRectangle(cornerRadius: Theme.cornerRadiusSM)
                    .strokeBorder(Color(red: 0.8, green: 0.7, blue: 0.3).opacity(0.6), lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if program.hasEnded {
            Theme.guidePast
        } else if isCurrentlyRecording {
            Theme.recording.opacity(0.3)
        } else if program.isCurrentlyAiring {
            Theme.guideNowPlaying
        } else if isScheduledRecording {
            Theme.guideScheduled
        } else {
            Theme.surfaceHighlight
        }
    }

    private var progressOverlay: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Theme.accent.opacity(0.3))
                .frame(width: geo.size.width * program.progress())
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: program.startDate)) - \(formatter.string(from: program.endDate))"
    }
}

#Preview {
    VStack(spacing: Theme.spacingMD) {
        ProgramCell(program: .preview, width: 200)

        ProgramCell(
            program: Program(
                id: 2,
                name: "Past Show",
                subtitle: "Episode 5",
                desc: nil,
                start: Int(Date().addingTimeInterval(-7200).timeIntervalSince1970),
                end: Int(Date().addingTimeInterval(-3600).timeIntervalSince1970),
                genres: nil,
                channelId: 1
            ),
            width: 200
        )

        ProgramCell(
            program: Program(
                id: 3,
                name: "Future Show",
                subtitle: nil,
                desc: nil,
                start: Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
                end: Int(Date().addingTimeInterval(7200).timeIntervalSince1970),
                genres: nil,
                channelId: 1
            ),
            width: 200,
            isScheduledRecording: true
        )
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
