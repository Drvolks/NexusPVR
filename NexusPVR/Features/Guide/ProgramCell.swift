//
//  ProgramCell.swift
//  nextpvr-apple-client
//
//  Individual program cell in the EPG grid
//

import SwiftUI

struct ProgramCell: View {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    let program: Program
    let width: CGFloat
    var isScheduledRecording: Bool = false
    var isCurrentlyRecording: Bool = false
    var matchesKeyword: Bool = false
    var detectedSport: Sport? = nil
    var leadingPadding: CGFloat = 0 // Padding for portion that's off-screen to the left

    private var showSportIcon: Bool {
        guard detectedSport != nil else { return false }
        #if os(tvOS)
        return width > 200
        #else
        return width > 100
        #endif
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Background
            backgroundView

            // Content - padded to align with visible portion
            HStack(spacing: 4) {
                if showSportIcon, let sport = detectedSport {
                    SportIconView(sport: sport, size: Theme.cellHeight - Theme.spacingXS * 2 - 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(program.cleanName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Text(timeString)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 0)

            }
            .padding(.leading, Theme.spacingSM + (program.isCurrentlyAiring ? leadingPadding : 0))
            .padding(.trailing, Theme.spacingSM)
            .padding(.vertical, Theme.spacingXS)

            // "New" green band on top-right corner
            if program.isNew {
                VStack {
                    HStack {
                        Spacer()
                        Theme.success
                            .frame(width: 6, height: 20)
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 3,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: Theme.cornerRadiusSM
                            ))
                    }
                    Spacer()
                }
            }

            // Recording red band on bottom-right corner
            if isCurrentlyRecording || isScheduledRecording {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Theme.recording
                            .frame(width: 6, height: 20)
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 3,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: Theme.cornerRadiusSM,
                                topTrailingRadius: 0
                            ))
                            .opacity(isCurrentlyRecording ? 1.0 : 0.6)
                    }
                }
            }

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
        "\(Self.timeFormatter.string(from: program.startDate)) - \(Self.timeFormatter.string(from: program.endDate))"
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
