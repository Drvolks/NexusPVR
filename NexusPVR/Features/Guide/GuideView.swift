//
//  GuideView.swift
//  nextpvr-apple-client
//
//  EPG grid view
//

import SwiftUI


// Helper struct to hold both program and channel for sheet presentation
private struct ProgramDetail: Identifiable {
    var id: Int { program.id }
    let program: Program
    let channel: Channel
}

struct GuideView: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var epgCache: EPGCache
    @StateObject private var viewModel = GuideViewModel()

    #if os(tvOS)
    /// Callback to request focus move to nav bar (called when pressing up at top row)
    var onRequestNavBarFocus: (() -> Void)? = nil
    #endif

    @State private var selectedProgramDetail: (program: Program, channel: Channel)?
    @State private var streamError: String?
    @State private var inProgressProgram: (program: Program, channel: Channel, recordingId: Int)?

    // Keywords for pre-computing matches
    @State private var keywords: [String] = []

    private let hourWidth: CGFloat = Theme.hourColumnWidth
    private let channelWidth: CGFloat = Theme.channelColumnWidth
    private let rowHeight: CGFloat = Theme.cellHeight

    #if DISPATCHERPVR
    private var hasFilterData: Bool {
        !epgCache.channelProfiles.isEmpty || hasPopulatedGroups
    }

    private var hasPopulatedGroups: Bool {
        epgCache.channelGroups.contains { group in
            epgCache.visibleChannels.contains { $0.groupId == group.id }
        }
    }
    #endif

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
                keywords = UserPreferences.load().keywords
                await viewModel.loadData(using: client, epgCache: epgCache)
                viewModel.updateKeywordMatches(keywords: keywords)
                #if os(iOS)
                if !appState.guideChannelFilter.isEmpty {
                    viewModel.channelSearchText = appState.guideChannelFilter
                }
                if let groupId = appState.guideGroupFilter {
                    viewModel.selectedGroupId = groupId
                }
                #endif
            }
            .onChange(of: viewModel.channelSearchText) {
                viewModel.updateKeywordMatches(keywords: keywords)
            }
            .onChange(of: epgCache.isFullyLoaded) {
                viewModel.updateKeywordMatches(keywords: keywords)
            }
            #if os(iOS)
            .onChange(of: appState.guideChannelFilter) {
                viewModel.channelSearchText = appState.guideChannelFilter
            }
            .onChange(of: appState.guideGroupFilter) {
                viewModel.selectedGroupId = appState.guideGroupFilter
            }
            #endif
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await refreshRecordings() }
                }
            }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var contentView: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            iOSNavigationBar
            #endif

            Group {
                if !epgCache.isFullyLoaded {
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
        .overlay(alignment: .top) {
            iOSNavigationBar
                .padding(.top, UIDevice.current.userInterfaceIdiom == .phone ? 30 : 0)
        }
        #endif
        #if os(iOS)
        .safeAreaPadding(.top, 0)
        #endif
    }

    private var programDetailBinding: Binding<ProgramDetail?> {
        Binding(
            get: { selectedProgramDetail.map { ProgramDetail(program: $0.program, channel: $0.channel) } },
            set: { selectedProgramDetail = $0.map { ($0.program, $0.channel) } }
        )
    }

    private func programDetailSheet(_ detail: ProgramDetail) -> some View {
        ProgramDetailView(
            program: detail.program,
            channel: detail.channel,
            initialRecordingId: viewModel.recordingId(for: detail.program)
        )
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
            appState.playStream(url: url, title: channel.name, channelId: channel.id, channelName: channel.name)
        } else {
            // Fall back to API call (required for Dispatcharr which uses UUID-based proxy URLs)
            Task {
                do {
                    let url = try await client.liveStreamURL(channelId: channel.id)
                    appState.playStream(url: url, title: channel.name, channelId: channel.id, channelName: channel.name)
                } catch {
                    streamError = error.localizedDescription
                }
            }
        }
    }

    #if !os(tvOS)
    private var iOSNavigationBar: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            HStack {
                HStack(spacing: 8) {
                    Button {
                        viewModel.previousDay()
                        Task { await viewModel.navigateToDate(using: client) }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32)
                    }

                    Text(viewModel.selectedDate, format: .dateTime.month(.abbreviated).day())
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    Button {
                        viewModel.nextDay()
                        Task { await viewModel.navigateToDate(using: client) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)

                Spacer()

                #if DISPATCHERPVR
                if hasFilterData {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            viewModel.showFilters.toggle()
                        }
                    } label: {
                        Image(systemName: viewModel.hasActiveFilters
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(viewModel.hasActiveFilters ? Theme.accent : Theme.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                    }
                }
                #endif
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.vertical, Theme.spacingSM)

            #if DISPATCHERPVR
            if viewModel.showFilters && hasFilterData {
                filterPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            #endif
            #else
            HStack(spacing: Theme.spacingMD) {
                Button {
                    viewModel.previousDay()
                    Task { await viewModel.navigateToDate(using: client) }
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
                    Task { await viewModel.navigateToDate(using: client) }
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
            #endif

            #if os(macOS)
            if viewModel.showChannelSearch {
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.textTertiary)
                    TextField("Filter channels", text: $viewModel.channelSearchText)
                        .textFieldStyle(.plain)
                    if !viewModel.channelSearchText.isEmpty {
                        Button {
                            viewModel.channelSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, Theme.spacingSM)
                .background(Theme.surface)
            }
            #endif
        }
    }
    #endif

    #if os(iOS)
    private var guideTopPadding: CGFloat {
        let base: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 80 : 55
        #if DISPATCHERPVR
        if viewModel.showFilters && hasFilterData {
            // Add space for each filter row shown
            var extra: CGFloat = 8 // top/bottom padding
            if !epgCache.channelProfiles.isEmpty { extra += 36 }
            if hasPopulatedGroups { extra += 36 }
            return base + extra
        }
        #endif
        return base
    }
    #endif

    #if DISPATCHERPVR
    @ViewBuilder
    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !epgCache.channelProfiles.isEmpty {
                filterRow(label: "Profile", items: epgCache.channelProfiles.map { (id: $0.id, name: $0.name) },
                          selectedId: viewModel.selectedProfileId) { id in
                    viewModel.selectedProfileId = id
                }
            }
            let populatedGroups = epgCache.channelGroups.filter { group in
                epgCache.visibleChannels.contains { $0.groupId == group.id }
            }
            if !populatedGroups.isEmpty {
                filterRow(label: "Group", items: populatedGroups.map { (id: $0.id, name: $0.name) },
                          selectedId: viewModel.selectedGroupId) { id in
                    viewModel.selectedGroupId = id
                }
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private func filterRow(label: String, items: [(id: Int, name: String)], selectedId: Int?, onSelect: @escaping (Int?) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 48, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterPill("All", isSelected: selectedId == nil) {
                        onSelect(nil)
                    }
                    ForEach(items, id: \.id) { item in
                        filterPill(item.name, isSelected: selectedId == item.id) {
                            onSelect(item.id)
                        }
                    }
                }
            }
        }
        .frame(height: 32)
    }

    private func filterPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Theme.accent : Color.white.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
                Task { await viewModel.loadData(using: client, epgCache: epgCache) }
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

    @State private var currentTimelineHour: Date?
    @State private var scrollTargetId: String?
    @State private var gridHorizontalOffset: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase

    #if os(tvOS)
    // tvOS manual focus tracking (like Rivulet approach)
    @State private var focusedRow: Int = 0
    @State private var focusedColumn: Int = 0
    @State private var timeOffset: Int = 0  // 30-minute increments from now
    @State private var guideStartTime: Date = {
        // Start from current time, rounded down to nearest 30 minutes
        let now = Date()
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: now)
        let roundedMinute = (minute / 30) * 30
        return calendar.date(bySettingHour: calendar.component(.hour, from: now),
                            minute: roundedMinute,
                            second: 0,
                            of: now) ?? now
    }()

    // Visible time window: 3 hours
    private let visibleHours: Double = 3.0
    private var visibleMinutes: Double { visibleHours * 60 }

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
    @State private var leadingSafeArea: CGFloat = 0
    @State private var scrollViewHeight: CGFloat = 0

    private var iOSMacOSGuideContent: some View {
        // Main grid — single LazyVStack for guaranteed lazy rendering
        // Channel cells pinned to left edge by counteracting horizontal scroll
        ScrollViewReader { programProxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                LazyVStack(spacing: 1) {
                    // Invisible scroll anchors for scroll-to-time
                    HStack(spacing: 0) {
                        Color.clear.frame(width: channelWidth + leadingSafeArea, height: 1)
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

                    #if os(iOS)
                    // Top padding so first row isn't behind the floating date pill + filter panel
                    Color.clear.frame(height: guideTopPadding)
                    #endif

                    ForEach(viewModel.channels) { channel in
                        ZStack(alignment: .leading) {
                            // Programs (scroll with content)
                            HStack(spacing: 0) {
                                Color.clear.frame(width: channelWidth + leadingSafeArea, height: rowHeight)
                                programsRow(channel)
                                    .frame(height: rowHeight)
                                    .background(Theme.surface)
                            }

                            // Channel cell pinned to visible left edge (after safe area)
                            channelCell(channel)
                                .frame(width: channelWidth, height: rowHeight)
                                .offset(x: gridHorizontalOffset + leadingSafeArea)
                                .zIndex(1)
                        }
                    }
                }
                .frame(minHeight: scrollViewHeight, alignment: .top)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.containerSize.height
            } action: { _, new in
                scrollViewHeight = new
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.x
            } action: { _, new in
                gridHorizontalOffset = new
            }
            .onAppear {
                updateScrollTarget()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if let targetId = scrollTargetId {
                        programProxy.scrollTo(targetId, anchor: UnitPoint(x: 0.10, y: 0))
                    }
                }
            }
            .onChange(of: viewModel.selectedDate) {
                updateScrollTarget()
            }
            .onChange(of: scrollTargetId) { _, newValue in
                if let targetId = newValue {
                    programProxy.scrollTo(targetId, anchor: UnitPoint(x: 0.10, y: 0))
                }
            }
        }
        .background(GeometryReader { geo in
            Color.clear.onAppear {
                leadingSafeArea = geo.safeAreaInsets.leading
            }
            .onChange(of: geo.safeAreaInsets.leading) { _, new in
                leadingSafeArea = new
            }
        })
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                viewModel.scrollToNow()
                updateScrollTarget()
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
                // Scroll back in time — focus on last program in new window
                timeOffset -= 1
                let newPrograms = tvOSVisiblePrograms(for: channels[focusedRow])
                focusedColumn = newPrograms.isEmpty ? 0 : newPrograms.count - 1
            }
        case .right:
            let programs = tvOSVisiblePrograms(for: channels[focusedRow])
            guard !programs.isEmpty else {
                // No programs visible — just scroll forward in time
                if timeOffset < 36 { timeOffset += 1 }
                focusedColumn = 0
                return
            }
            if focusedColumn < programs.count - 1 {
                focusedColumn += 1
            } else if timeOffset < 36 {  // Max 18 hours ahead (36 x 30min)
                // Scroll forward in time — focus on first program after the current one
                let safeColumn = min(focusedColumn, programs.count - 1)
                let lastProgram = programs[safeColumn]
                timeOffset += 1
                let newPrograms = tvOSVisiblePrograms(for: channels[focusedRow])
                if let nextIndex = newPrograms.firstIndex(where: { $0.startDate > lastProgram.startDate }) {
                    focusedColumn = nextIndex
                } else {
                    focusedColumn = max(0, newPrograms.count - 1)
                }
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
        .accessibilityIdentifier("guide-channel-\(channel.id)")
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
                let matchesKeywords = viewModel.keywordMatchedProgramIds.contains(program.id)
                let sport = viewModel.detectedSport(for: program)
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
                        detectedSport: sport,
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
                .accessibilityIdentifier("guide-program-\(program.id)")
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

    private func updateScrollTarget() {
        let calendar = Calendar.current
        let now = Date()
        let isToday = calendar.isDate(viewModel.selectedDate, inSameDayAs: now)

        // For today, scroll to current time; for other days, scroll to start of day
        let targetTime = isToday ? now : viewModel.timelineStart
        let scrollTargetDate = GuideScrollHelper.calculateScrollTarget(currentTime: targetTime)

        // Store scroll target for text padding calculation
        currentTimelineHour = scrollTargetDate

        // Find the hour marker in hoursToShow and scroll to the appropriate anchor
        let targetHourComponent = calendar.component(.hour, from: targetTime)
        if let targetHour = viewModel.hoursToShow.first(where: { calendar.component(.hour, from: $0) == targetHourComponent }) {
            scrollTargetId = GuideScrollHelper.calculateScrollId(currentTime: targetTime, targetHour: targetHour)
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

}

#Preview {
    GuideView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .environmentObject(EPGCache())
        .preferredColorScheme(.dark)
}
