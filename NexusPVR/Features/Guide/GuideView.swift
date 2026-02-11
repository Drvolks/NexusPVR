//
//  GuideView.swift
//  nextpvr-apple-client
//
//  EPG grid view
//

import SwiftUI

// PreferenceKey for tracking horizontal scroll offset (to sync timeline header)
private struct HorizontalScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}



// Helper struct to hold both program and channel for sheet presentation
private struct ProgramDetail: Identifiable {
    let id = UUID()
    let program: Program
    let channel: Channel
}

struct GuideView: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = GuideViewModel()

    #if os(tvOS)
    /// Callback to request focus move to nav bar (called when pressing up at top row)
    var onRequestNavBarFocus: (() -> Void)? = nil
    #endif

    @State private var selectedProgramDetail: (program: Program, channel: Channel)?
    @State private var streamError: String?
    @State private var inProgressProgram: (program: Program, channel: Channel, recordingId: Int)?

    // Cache keywords to avoid disk I/O during rendering
    @State private var cachedKeywords: [String] = []

    private let hourWidth: CGFloat = Theme.hourColumnWidth
    private let channelWidth: CGFloat = Theme.channelColumnWidth
    private let rowHeight: CGFloat = Theme.cellHeight

    var body: some View {
        contentView
            .background(Theme.background)
            #if os(macOS)
            .toolbar(.hidden)
            #endif
            .sheet(item: programDetailBinding, onDismiss: onDismissDetail) { detail in
                programDetailSheet(detail)
            }
            .confirmationDialog("Recording in Progress",
                                isPresented: .constant(inProgressProgram != nil),
                                presenting: inProgressProgram) { info in
                Button("Watch from Beginning") {
                    Task {
                        do {
                            let url = try await client.recordingStreamURL(recordingId: info.recordingId)
                            appState.playStream(url: url, title: info.program.name, recordingId: info.recordingId)
                        } catch {
                            streamError = error.localizedDescription
                        }
                    }
                    inProgressProgram = nil
                }
                Button("Watch Live") {
                    playLiveChannel(info.channel)
                    inProgressProgram = nil
                }
                Button("Cancel", role: .cancel) {
                    inProgressProgram = nil
                }
            } message: { info in
                Text("\(info.program.name) is currently recording.")
            }
            .alert("Error", isPresented: .constant(streamError != nil)) {
                Button("OK") { streamError = nil }
            } message: {
                streamErrorMessage
            }
            .task {
                cachedKeywords = UserPreferences.load().keywords
                await viewModel.loadData(using: client)
            }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var contentView: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            iOSNavigationBar
                // Extra padding for Dynamic Island on iPhone (compact width)
                .padding(.top, horizontalSizeClass == .compact ? 16 : 0)
            #elseif os(macOS)
            iOSNavigationBar
            #endif

            Group {
                if (viewModel.isLoading || !viewModel.hasLoaded) && viewModel.channels.isEmpty {
                    loadingView
                } else if let error = viewModel.error, viewModel.channels.isEmpty {
                    errorView(error)
                } else if viewModel.hasLoaded && viewModel.channels.isEmpty {
                    emptyView
                } else {
                    guideContent
                }
            }
        }
        #if os(iOS)
        .safeAreaPadding(.top)
        #endif
    }

    private var programDetailBinding: Binding<ProgramDetail?> {
        Binding(
            get: { selectedProgramDetail.map { ProgramDetail(program: $0.program, channel: $0.channel) } },
            set: { selectedProgramDetail = $0.map { ($0.program, $0.channel) } }
        )
    }

    private func programDetailSheet(_ detail: ProgramDetail) -> some View {
        ProgramDetailView(program: detail.program, channel: detail.channel)
            .environmentObject(client)
            .environmentObject(appState)
    }

    private func onDismissDetail() {
        Task {
            await refreshRecordings()
        }
    }

    @ViewBuilder
    private var streamErrorMessage: some View {
        if let error = streamError {
            Text(error)
        }
    }

    private func playLiveChannel(_ channel: Channel) {
        // Use the direct stream URL from channelDetails if available
        if let urlString = channel.streamURL, let url = URL(string: urlString) {
            #if DEBUG
            print("Playing channel stream: \(url.absoluteString)")
            #endif
            appState.playStream(url: url, title: channel.name)
        } else {
            // Fall back to API call (required for Dispatcharr which uses UUID-based proxy URLs)
            Task {
                do {
                    let url = try await client.liveStreamURL(channelId: channel.id)
                    appState.playStream(url: url, title: channel.name)
                } catch {
                    streamError = error.localizedDescription
                }
            }
        }
    }

    #if !os(tvOS)
    private var iOSNavigationBar: some View {
        HStack(spacing: Theme.spacingMD) {
            Button {
                viewModel.previousDay()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceElevated)
                    .clipShape(Circle())
            }

            Text(viewModel.selectedDate, format: .dateTime.month(.abbreviated).day())
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 80)

            Button {
                viewModel.nextDay()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceElevated)
                    .clipShape(Circle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingSM)
        .background(Theme.surface)
    }
    #endif

    private var loadingView: some View {
        VStack(spacing: Theme.spacingMD) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.accent)
            Text("Loading guide...")
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.warning)
            Text("Unable to load guide")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await viewModel.loadData(using: client) }
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "tv")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No channels available")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(Brand.configureServerMessage)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var horizontalScrollOffset: CGFloat = 0
    @State private var scrollProxy: ScrollViewProxy?
    @State private var currentTimelineHour: Date?
    @State private var scrollTargetId: String?
    @Environment(\.scenePhase) private var scenePhase

    #if os(tvOS)
    // tvOS manual focus tracking (like Rivulet approach)
    @State private var focusedRow: Int = 0
    @State private var focusedColumn: Int = 0
    @State private var timeOffset: Int = 0  // 30-minute increments from now

    // Visible time window: 3 hours
    private let visibleHours: Double = 3.0
    private var visibleMinutes: Double { visibleHours * 60 }

    private var guideStartTime: Date {
        // Start from current time, rounded down to nearest 30 minutes
        let now = Date()
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: now)
        let roundedMinute = (minute / 30) * 30
        return calendar.date(bySettingHour: calendar.component(.hour, from: now),
                            minute: roundedMinute,
                            second: 0,
                            of: now) ?? now
    }

    private var visibleStart: Date {
        guideStartTime.addingTimeInterval(Double(timeOffset * 30 * 60))
    }

    private var visibleEnd: Date {
        visibleStart.addingTimeInterval(visibleMinutes * 60)
    }
    #endif

    private var guideContent: some View {
        #if os(tvOS)
        tvOSGuideContent
        #else
        iOSMacOSGuideContent
        #endif
    }

    #if !os(tvOS)
    private var iOSMacOSGuideContent: some View {
        VStack(spacing: 0) {
            // Timeline header (with spacer for channel column)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: channelWidth, height: 30)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        timelineHeaderContent
                    }
                    .onAppear {
                        scrollProxy = proxy
                        scrollToCurrentTime(proxy: proxy)
                    }
                    .onChange(of: viewModel.selectedDate) {
                        scrollToCurrentTime(proxy: proxy)
                    }
                }
            }

            // Main grid
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    // Channel column (fixed horizontally, scrolls vertically)
                    VStack(spacing: 1) {
                        ForEach(viewModel.channels) { channel in
                            channelCell(channel)
                                .frame(width: channelWidth, height: rowHeight)
                        }
                    }
                    .frame(width: channelWidth)

                    // All programs in single horizontal scroll (scroll together)
                    ScrollViewReader { programProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(spacing: 1) {
                                // Invisible scroll anchors matching timeline header IDs
                                HStack(spacing: 0) {
                                    ForEach(viewModel.hoursToShow, id: \.self) { hour in
                                        HStack(spacing: 0) {
                                            Color.clear
                                                .frame(width: hourWidth / 2, height: 1)
                                                .id("scroll-\(hour.timeIntervalSince1970)")
                                            Color.clear
                                                .frame(width: hourWidth / 2, height: 1)
                                                .id("scroll-\(hour.timeIntervalSince1970 + 1800)")
                                        }
                                    }
                                }
                                .frame(height: 0)

                                ForEach(viewModel.channels) { channel in
                                    programsRow(channel)
                                        .frame(height: rowHeight)
                                        .background(Theme.surface)
                                }
                            }
                        }
                        .onAppear {
                            // Initial scroll to current time for programs
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                if let targetId = scrollTargetId {
                                    programProxy.scrollTo(targetId, anchor: UnitPoint(x: 0, y: 0))
                                }
                            }
                        }
                        .onChange(of: scrollTargetId) { _, newValue in
                            if let targetId = newValue {
                                programProxy.scrollTo(targetId, anchor: UnitPoint(x: 0, y: 0))
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                // When app becomes active, scroll to current time
                viewModel.scrollToNow()
                if let proxy = scrollProxy {
                    scrollToCurrentTime(proxy: proxy)
                }
            }
        }
    }
    #endif

    #if os(tvOS)
    private var tvOSGuideContent: some View {
        GeometryReader { geometry in
            let gridWidth = geometry.size.width - channelWidth
            let pxPerMinute = gridWidth / visibleMinutes

            // Wrap entire grid in a Button to capture all focus/input
            Button {
                selectFocusedProgram()
            } label: {
                VStack(spacing: 0) {
                    // Time header
                    tvOSTimeHeader(gridWidth: gridWidth, pxPerMinute: pxPerMinute)

                    // Grid with manual focus tracking
                    ScrollViewReader { verticalProxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(viewModel.channels.enumerated()), id: \.element.id) { rowIndex, channel in
                                    tvOSChannelRow(
                                        channel: channel,
                                        rowIndex: rowIndex,
                                        gridWidth: gridWidth,
                                        pxPerMinute: pxPerMinute
                                    )
                                    .id(rowIndex)
                                }
                            }
                        }
                        .onChange(of: focusedRow) { _, newRow in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                verticalProxy.scrollTo(newRow, anchor: .center)
                            }
                        }
                    }
                }
            }
            .buttonStyle(TVGridContainerButtonStyle())
            .onMoveCommand { direction in
                handleTVNavigation(direction)
            }
            .onPlayPauseCommand {
                selectFocusedProgram()
            }
            .contextMenu {
                if let info = focusedProgramInfo {
                    tvOSContextMenuItems(program: info.program, channel: info.channel)
                }
            }
        }
        .ignoresSafeArea(.all, edges: .leading)
    }

    /// Button style that makes the grid container fill available space with no visual changes
    struct TVGridContainerButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tvOSTimeHeader(gridWidth: CGFloat, pxPerMinute: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Empty space for channel column
            Rectangle()
                .fill(Theme.surfaceElevated)
                .frame(width: channelWidth, height: 40)

            // Time slots
            HStack(spacing: 0) {
                ForEach(0..<Int(visibleHours * 2), id: \.self) { slot in
                    let slotTime = visibleStart.addingTimeInterval(Double(slot * 30 * 60))
                    Text(slotTime, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: pxPerMinute * 30, alignment: .leading)
                        .padding(.leading, 8)
                }
            }
            .frame(width: gridWidth)
        }
        .background(Theme.surfaceElevated)
    }

    private func tvOSChannelRow(channel: Channel, rowIndex: Int, gridWidth: CGFloat, pxPerMinute: CGFloat) -> some View {
        let isRowFocused = rowIndex == focusedRow
        let programs = tvOSVisiblePrograms(for: channel)

        return HStack(spacing: 0) {
            // Channel cell
            tvOSChannelCell(channel: channel, isSelected: isRowFocused)

            // Programs row
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(isRowFocused ? Color(white: 0.08) : Color(white: 0.05))

                if programs.isEmpty {
                    Text("No Data")
                        .font(.headline)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 16)
                } else {
                    ForEach(Array(programs.enumerated()), id: \.element.id) { colIndex, program in
                        let isFocused = isRowFocused && colIndex == focusedColumn
                        tvOSProgramCell(
                            program: program,
                            isFocused: isFocused,
                            gridWidth: gridWidth,
                            pxPerMinute: pxPerMinute
                        )
                    }
                }
            }
            .frame(width: gridWidth, height: rowHeight)
            .clipped()
        }
        .frame(height: rowHeight)
    }

    private func tvOSChannelCell(channel: Channel, isSelected: Bool) -> some View {
        CachedAsyncImage(url: client.channelIconURL(channelId: channel.id)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            Image(systemName: "tv")
                .font(.title)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(width: 80, height: 60)
        .frame(width: channelWidth, height: rowHeight)
        .background(isSelected ? Color(white: 0.15) : Theme.surfaceElevated)
    }

    private func tvOSProgramCell(program: Program, isFocused: Bool, gridWidth: CGFloat, pxPerMinute: CGFloat) -> some View {
        let (xPos, cellWidth) = tvOSProgramPosition(program: program, pxPerMinute: pxPerMinute)
        let isAiring = program.isCurrentlyAiring
        let isScheduled = viewModel.isScheduledRecording(program)
        let isRecording = isScheduled && isAiring && viewModel.recordingStatus(program) == .recording

        let bgColor: Color = {
            if isFocused {
                return Theme.accent
            } else if isRecording {
                return Theme.recording.opacity(0.3)
            } else if isAiring {
                return Color(white: 0.18)
            } else {
                return Color(white: 0.12)
            }
        }()

        let showSport = cellWidth > 200
        let sportIconSize = rowHeight - 10 - 16 // cell height minus padding

        return HStack(spacing: 6) {
            if showSport, let sport = SportDetector.detect(from: program) {
                SportIconView(sport: sport, size: sportIconSize)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(program.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isFocused ? .white : Theme.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if isScheduled {
                        Image(systemName: "record.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.recording)
                    }
                }

                Text(program.startDate, format: .dateTime.hour().minute())
                    .font(.system(size: 14))
                    .foregroundStyle(isFocused ? .white.opacity(0.8) : Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: max(cellWidth - 4, 80), height: rowHeight - 10, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(bgColor))
        .shadow(color: isFocused ? .black.opacity(0.5) : .clear, radius: 10, x: 0, y: 4)
        .scaleEffect(isFocused ? 1.02 : 1.0, anchor: .leading)
        .zIndex(isFocused ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .offset(x: xPos + 2)
    }

    private func tvOSProgramPosition(program: Program, pxPerMinute: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let progVisibleStart = max(program.startDate, visibleStart)
        let progVisibleEnd = min(program.endDate, visibleEnd)

        let x = CGFloat(progVisibleStart.timeIntervalSince(visibleStart) / 60) * pxPerMinute
        let width = max(CGFloat(progVisibleEnd.timeIntervalSince(progVisibleStart) / 60) * pxPerMinute, 80)

        return (x, width)
    }

    private func tvOSVisiblePrograms(for channel: Channel) -> [Program] {
        let programs = viewModel.visiblePrograms(for: channel)
        return programs.filter { program in
            program.endDate > visibleStart && program.startDate < visibleEnd
        }
    }

    private func handleTVNavigation(_ direction: MoveCommandDirection) {
        let channels = viewModel.channels
        guard !channels.isEmpty else { return }

        switch direction {
        case .up:
            if focusedRow > 0 {
                focusedRow -= 1
                clampColumn()
            } else {
                // At top row - request focus move to nav bar
                onRequestNavBarFocus?()
            }
        case .down:
            if focusedRow < channels.count - 1 {
                focusedRow += 1
                clampColumn()
            }
        case .left:
            if focusedColumn > 0 {
                focusedColumn -= 1
            } else if timeOffset > 0 {
                // Scroll back in time
                timeOffset -= 1
                // Keep focus on first visible program
                focusedColumn = 0
            }
        case .right:
            let programs = tvOSVisiblePrograms(for: channels[focusedRow])
            if focusedColumn < programs.count - 1 {
                focusedColumn += 1
            } else if timeOffset < 36 {  // Max 18 hours ahead (36 x 30min)
                // Scroll forward in time
                timeOffset += 1
                focusedColumn = 0
            }
        @unknown default:
            break
        }
    }

    private func clampColumn() {
        guard focusedRow < viewModel.channels.count else { return }
        let programs = tvOSVisiblePrograms(for: viewModel.channels[focusedRow])
        focusedColumn = min(focusedColumn, max(0, programs.count - 1))
    }

    private func selectFocusedProgram() {
        guard focusedRow < viewModel.channels.count else { return }
        let channel = viewModel.channels[focusedRow]
        let programs = tvOSVisiblePrograms(for: channel)
        guard focusedColumn < programs.count else { return }
        let program = programs[focusedColumn]

        if program.isCurrentlyAiring {
            playLiveChannel(channel)
        } else {
            selectedProgramDetail = (program: program, channel: channel)
        }
    }

    private var focusedProgramInfo: (program: Program, channel: Channel)? {
        let channels = viewModel.channels
        guard focusedRow < channels.count else { return nil }
        let channel = channels[focusedRow]
        let programs = tvOSVisiblePrograms(for: channel)
        guard focusedColumn < programs.count else { return nil }
        return (programs[focusedColumn], channel)
    }

    @ViewBuilder
    private func tvOSContextMenuItems(program: Program, channel: Channel) -> some View {
        if program.isCurrentlyAiring, let recId = viewModel.activeRecordingId(for: program, channelId: channel.id) {
            Button {
                Task {
                    do {
                        let url = try await client.recordingStreamURL(recordingId: recId)
                        appState.playStream(url: url, title: program.name, recordingId: recId)
                    } catch {
                        streamError = error.localizedDescription
                    }
                }
            } label: {
                Label("Watch from Beginning", systemImage: "play.fill")
            }
            Button {
                playLiveChannel(channel)
            } label: {
                Label("Watch Live", systemImage: "dot.radiowaves.left.and.right")
            }
            Button {
                Task {
                    try? await client.cancelRecording(recordingId: recId)
                    await viewModel.reloadRecordings(client: client)
                }
            } label: {
                Label("Cancel Recording", systemImage: "xmark.circle")
            }
        } else if viewModel.isScheduledRecording(program), let recId = viewModel.recordingId(for: program) {
            Button {
                Task {
                    try? await client.cancelRecording(recordingId: recId)
                    await viewModel.reloadRecordings(client: client)
                }
            } label: {
                Label("Cancel Recording", systemImage: "xmark.circle")
            }
        } else if !program.hasEnded {
            Button {
                Task {
                    try? await client.scheduleRecording(eventId: program.id)
                    await viewModel.reloadRecordings(client: client)
                }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
        }

        Button {
            selectedProgramDetail = (program: program, channel: channel)
        } label: {
            Label("Details", systemImage: "info.circle")
        }
    }
    #endif

    private var timelineHeaderContent: some View {
        HStack(spacing: 0) {
            // Hour markers with :00 and :30 scroll anchors
            ForEach(viewModel.hoursToShow, id: \.self) { hour in
                HStack(spacing: 0) {
                    // :00 half with hour label
                    Text(hour, format: .dateTime.hour())
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: hourWidth / 2, alignment: .leading)
                        .padding(.leading, Theme.spacingSM)
                        .id("scroll-\(hour.timeIntervalSince1970)")
                    // :30 half (empty)
                    Color.clear
                        .frame(width: hourWidth / 2)
                        .id("scroll-\(hour.timeIntervalSince1970 + 1800)")
                }
            }
        }
        .frame(height: 30)
        .background(Theme.surfaceElevated)
    }

    @ViewBuilder
    private func channelCell(_ channel: Channel) -> some View {
        #if os(tvOS)
        // tvOS: non-interactive channel icon - logo fills the cell
        CachedAsyncImage(url: client.channelIconURL(channelId: channel.id)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            ProgressView()
                .scaleEffect(0.5)
        }
        .padding(Theme.spacingSM)
        .frame(width: channelWidth, height: rowHeight)
        .background(Theme.surfaceElevated)
        #else
        // iOS/macOS: tappable to play live
        Button {
            playLiveChannel(channel)
        } label: {
            ZStack {
                CachedAsyncImage(url: client.channelIconURL(channelId: channel.id)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView()
                        .scaleEffect(0.5)
                }
                .frame(width: Theme.iconSize, height: Theme.iconSize)

                // Play indicator on hover/focus
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.caption)
                    .offset(x: Theme.iconSize * 0.35, y: Theme.iconSize * 0.35)
            }
            .frame(width: channelWidth, height: rowHeight)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        }
        .buttonStyle(.plain)
        #endif
    }

    private func programsRow(_ channel: Channel) -> some View {
        let timelineStart = viewModel.timelineStart
        let programs = viewModel.visiblePrograms(for: channel)
        // Calculate scroll target: :00 or :30 based on current minute
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: Date())

        return ZStack(alignment: .leading) {
            // Background for the full timeline
            Color.clear
                .frame(width: hourWidth * 24)

            // Program cells
            ForEach(programs) { program in
                let isScheduled = viewModel.isScheduledRecording(program)
                let status = viewModel.recordingStatus(program)
                let isRecording = isScheduled && program.isCurrentlyAiring && status == .recording
                let matchesKeywords = matchesKeywords(program)
                // Calculate leading padding for live programs - push text to visible left edge (scroll target)
                let leadingPad = GuideScrollHelper.calculateLeadingPadding(
                    programStart: program.startDate,
                    scrollTarget: scrollTarget,
                    hourWidth: hourWidth,
                    isCurrentlyAiring: program.isCurrentlyAiring
                )

                Button {
                    #if os(tvOS)
                    // tvOS: recording in progress shows options, live plays directly
                    if program.isCurrentlyAiring, let recId = viewModel.activeRecordingId(for: program, channelId: channel.id) {
                        inProgressProgram = (program: program, channel: channel, recordingId: recId)
                    } else if program.isCurrentlyAiring {
                        playLiveChannel(channel)
                    } else {
                        selectedProgramDetail = (program: program, channel: channel)
                    }
                    #else
                    selectedProgramDetail = (program: program, channel: channel)
                    #endif
                } label: {
                    ProgramCell(
                        program: program,
                        width: viewModel.programWidth(for: program, hourWidth: hourWidth, startTime: timelineStart),
                        isScheduledRecording: isScheduled,
                        isCurrentlyRecording: isRecording,
                        matchesKeyword: matchesKeywords,
                        leadingPadding: leadingPad
                    )
                }
                #if os(tvOS)
                .buttonStyle(TVGuideButtonStyle())
                .focusEffectDisabled()
                .contextMenu {
                    if program.isCurrentlyAiring, let recId = viewModel.activeRecordingId(for: program, channelId: channel.id) {
                        Button {
                            Task {
                                do {
                                    let url = try await client.recordingStreamURL(recordingId: recId)
                                    appState.playStream(url: url, title: program.name, recordingId: recId)
                                } catch {
                                    streamError = error.localizedDescription
                                }
                            }
                        } label: {
                            Label("Watch from Beginning", systemImage: "play.fill")
                        }

                        Button {
                            playLiveChannel(channel)
                        } label: {
                            Label("Watch Live", systemImage: "dot.radiowaves.left.and.right")
                        }

                        Button {
                            Task {
                                try? await client.cancelRecording(recordingId: recId)
                                await viewModel.reloadRecordings(client: client)
                            }
                        } label: {
                            Label("Cancel Recording", systemImage: "xmark.circle")
                        }
                    } else if program.isCurrentlyAiring {
                        Button {
                            selectedProgramDetail = (program: program, channel: channel)
                        } label: {
                            Label("Details", systemImage: "info.circle")
                        }

                        if !isScheduled {
                            Button {
                                selectedProgramDetail = (program: program, channel: channel)
                            } label: {
                                Label("Record", systemImage: "record.circle")
                            }
                        }
                    }
                }
                #else
                .buttonStyle(.plain)
                .contextMenu {
                    if program.isCurrentlyAiring, let recId = viewModel.activeRecordingId(for: program, channelId: channel.id) {
                        Button {
                            Task {
                                do {
                                    let url = try await client.recordingStreamURL(recordingId: recId)
                                    appState.playStream(url: url, title: program.name, recordingId: recId)
                                } catch {
                                    streamError = error.localizedDescription
                                }
                            }
                        } label: {
                            Label("Watch from Beginning", systemImage: "play.fill")
                        }

                        Button {
                            playLiveChannel(channel)
                        } label: {
                            Label("Watch Live", systemImage: "dot.radiowaves.left.and.right")
                        }

                        Button {
                            Task {
                                try? await client.cancelRecording(recordingId: recId)
                                await viewModel.reloadRecordings(client: client)
                            }
                        } label: {
                            Label("Cancel Recording", systemImage: "xmark.circle")
                        }
                    } else if !program.hasEnded {
                        if isScheduled, let recId = viewModel.recordingId(for: program) {
                            Button {
                                Task {
                                    try? await client.cancelRecording(recordingId: recId)
                                    await viewModel.reloadRecordings(client: client)
                                }
                            } label: {
                                Label("Cancel Recording", systemImage: "xmark.circle")
                            }
                        } else {
                            Button {
                                Task {
                                    try? await client.scheduleRecording(eventId: program.id)
                                    await viewModel.reloadRecordings(client: client)
                                }
                            } label: {
                                Label("Record", systemImage: "record.circle")
                            }
                        }
                    }

                    Button {
                        selectedProgramDetail = (program: program, channel: channel)
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                }
                #endif
                .offset(x: viewModel.programOffset(for: program, hourWidth: hourWidth, startTime: timelineStart))
            }

            // Now indicator
            nowIndicator(timelineStart: timelineStart)
        }
        .frame(width: hourWidth * 24, height: rowHeight)
    }

    @ViewBuilder
    private func nowIndicator(timelineStart: Date) -> some View {
        let now = Date()
        if now >= timelineStart && now < timelineStart.addingTimeInterval(24 * 3600) {
            let offset = CGFloat(now.timeIntervalSince(timelineStart) / 3600) * hourWidth
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
                .offset(x: offset)
        }
    }

    private func scrollToCurrentTime(proxy: ScrollViewProxy, isInitialLoad: Bool = false) {
        let calendar = Calendar.current
        let now = Date()

        // Only scroll to current time if viewing today
        guard calendar.isDate(viewModel.selectedDate, inSameDayAs: now) else { return }

        // Calculate the target scroll position using helper
        let scrollTargetDate = GuideScrollHelper.calculateScrollTarget(currentTime: now)

        // Store scroll target for text padding calculation
        currentTimelineHour = scrollTargetDate

        // Find the hour marker in hoursToShow and scroll to the appropriate :00 or :30 anchor
        let currentHour = calendar.component(.hour, from: now)
        if let targetHour = viewModel.hoursToShow.first(where: { calendar.component(.hour, from: $0) == currentHour }) {
            let scrollId = GuideScrollHelper.calculateScrollId(currentTime: now, targetHour: targetHour)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(isInitialLoad ? nil : .default) {
                    // Scroll timeline header
                    proxy.scrollTo(scrollId, anchor: UnitPoint(x: 0, y: 0))
                    // Update shared target to scroll all program rows
                    scrollTargetId = scrollId
                }
            }
        }
    }

    private func refreshRecordings() async {
        do {
            let (completed, recording, scheduled) = try await client.getAllRecordings()
            viewModel.recordings = completed + recording + scheduled
        } catch {
            // Silently fail - the grid just won't update the indicators
        }
    }

    private func matchesKeywords(_ program: Program) -> Bool {
        guard !cachedKeywords.isEmpty else { return false }

        let searchText = [
            program.name,
            program.subtitle ?? "",
            program.desc ?? ""
        ].joined(separator: " ").lowercased()

        return cachedKeywords.contains { keyword in
            searchText.contains(keyword.lowercased())
        }
    }
}

#Preview {
    GuideView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
