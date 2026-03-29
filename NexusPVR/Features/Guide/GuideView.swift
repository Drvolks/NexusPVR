//
//  GuideView.swift
//  nextpvr-apple-client
//
//  EPG grid view
//

import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif


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
    #if os(iOS)
    @EnvironmentObject var viewModel: GuideViewModel
    #else
    @StateObject private var viewModel = GuideViewModel()
    #endif

    #if os(tvOS)
    /// Callback to request focus move to nav bar (called when pressing up at top row)
    var onRequestNavBarFocus: (() -> Void)? = nil
    #endif

    @State private var selectedProgramDetail: (program: Program, channel: Channel)?
    @State private var streamError: String?

    // Keywords for pre-computing matches
    @State private var keywords: [String] = []

    #if !os(tvOS)
    @StateObject private var calendarViewModel = TopicsViewModel()
    #endif

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
            .accessibilityIdentifier("guide-view")
            .background(.ultraThinMaterial)
            #if os(macOS)
            .toolbar(.hidden)
            #endif
            .sheet(item: programDetailBinding, onDismiss: onDismissDetail) { detail in
                programDetailSheet(detail)
            }
            .alert("Error", isPresented: .constant(streamError != nil)) {
                Button("OK") { streamError = nil }
            } message: {
                streamErrorMessage
            }
            #if os(macOS)
            .onChange(of: appState.showingCalendar) {
                if appState.showingCalendar {
                    calendarViewModel.epgCache = epgCache
                    calendarViewModel.client = client
                    Task { await calendarViewModel.loadData() }
                }
            }
            .sheet(isPresented: $appState.showingCalendar) {
                CalendarView(programs: calendarViewModel.matchingPrograms)
                    .environmentObject(client)
                    .environmentObject(appState)
                    .frame(minWidth: 700, minHeight: 500)
            }
            .sheet(isPresented: $appState.showingKeywordsEditor) {
                KeywordsEditorView()
                    .onDisappear {
                        keywords = UserPreferences.load().keywords
                        viewModel.updateKeywordMatches(keywords: keywords)
                    }
                    .frame(minWidth: 500, minHeight: 400)
            }
            #endif
            .task {
                keywords = UserPreferences.load().keywords
                await viewModel.loadData(using: client, epgCache: epgCache)
                viewModel.updateKeywordMatches(keywords: keywords)
                #if !os(tvOS)
                if !appState.guideChannelFilter.isEmpty {
                    viewModel.channelSearchText = appState.guideChannelFilter
                }
                if let groupId = appState.guideGroupFilter {
                    viewModel.selectedGroupId = groupId
                }
                #endif
            }
            .onChange(of: viewModel.channelSearchText) {
                Task { viewModel.updateKeywordMatches(keywords: keywords) }
            }
            .onChange(of: epgCache.isFullyLoaded) {
                Task { viewModel.updateKeywordMatches(keywords: keywords) }
            }
            #if !os(tvOS)
            .onChange(of: appState.guideChannelFilter) {
                Task { viewModel.channelSearchText = appState.guideChannelFilter }
            }
            .onChange(of: appState.guideGroupFilter) {
                Task { viewModel.selectedGroupId = appState.guideGroupFilter }
            }
            #endif
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await refreshRecordings() }
                    #if os(tvOS)
                    // Resync the guide start time so the visible window matches
                    // the ViewModel's timelineStart (which uses current time)
                    let now = Date()
                    let calendar = Calendar.current
                    let minute = calendar.component(.minute, from: now)
                    let roundedMinute = (minute / 30) * 30
                    if let newStart = calendar.date(bySettingHour: calendar.component(.hour, from: now),
                                                    minute: roundedMinute, second: 0, of: now) {
                        guideStartTime = newStart
                        timeOffset = 0
                    }
                    #endif
                }
            }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var rootLeadingSafeArea: CGFloat = 0
    @State private var rootTopSafeArea: CGFloat = 0

    private var contentView: some View {
        VStack(spacing: 0) {
            Group {
                if let error = epgCache.error {
                    errorView(error)
                } else if !epgCache.isFullyLoaded {
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
        #if os(macOS)
        .overlay(alignment: .top) {
            macOSGuideNavBar
        }
        #endif
        #if os(iOS) && DISPATCHERPVR
        .overlay(alignment: .top) {
            if viewModel.showFilters && hasFilterData {
                filterPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        #endif
        .background(GeometryReader { geo in
            Color.clear
                .onAppear {
                    rootLeadingSafeArea = geo.safeAreaInsets.leading
                    #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom != .phone {
                        rootTopSafeArea = geo.safeAreaInsets.top
                    }
                    #else
                    rootTopSafeArea = geo.safeAreaInsets.top
                    #endif
                }
                .onChange(of: geo.safeAreaInsets.leading) { _, new in
                    rootLeadingSafeArea = new
                }
                .onChange(of: geo.safeAreaInsets.top) { _, new in
                    #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom != .phone {
                        rootTopSafeArea = new
                    }
                    #else
                    rootTopSafeArea = new
                    #endif
                }
        })
        #if os(iOS)
        .onAppear {
            schedulePhoneSafeAreaRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            schedulePhoneSafeAreaRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            schedulePhoneSafeAreaRefresh()
        }
        .onChange(of: horizontalSizeClass) {
            schedulePhoneSafeAreaRefresh()
        }
        .onChange(of: verticalSizeClass) {
            schedulePhoneSafeAreaRefresh()
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
        Task {
            do {
                let url = try await client.liveStreamURL(channelId: channel.id)
                appState.playStream(url: url, title: channel.name, channelId: channel.id, channelName: channel.name)
            } catch {
                streamError = error.localizedDescription
            }
        }
    }

    #if os(iOS)
    private func schedulePhoneSafeAreaRefresh() {
        // Rotation can report stale insets for a short window. Refresh a few times.
        refreshPhoneSafeAreasFromWindow()
        DispatchQueue.main.async {
            refreshPhoneSafeAreasFromWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            refreshPhoneSafeAreasFromWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            refreshPhoneSafeAreasFromWindow()
        }
    }

    private func refreshPhoneSafeAreasFromWindow() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        let insets = window.safeAreaInsets
        // Use live per-orientation values (do not keep stale larger inset)
        rootLeadingSafeArea = insets.left
        // Visual compensation: raw top inset sits slightly too low for the guide header.
        rootTopSafeArea = (verticalSizeClass == .some(.compact)) ? 0 : max(0, insets.top - 40)
    }
    #endif

    #if os(macOS)
    private var macOSGuideNavBar: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        viewModel.previousDay()
                        Task { await viewModel.navigateToDate(using: client) }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(viewModel.isOnToday ? Theme.textTertiary : Theme.accent)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isOnToday)

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
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
                    .padding(.trailing, Theme.spacingSM)
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
        }
    }
    #endif

    #if !os(tvOS)

    private var guideTopPadding: CGFloat {
        #if os(iOS)
        // Top bar is now a safeAreaInset in IOSNavigation, no extra offset needed
        let base: CGFloat = 0
        #else
        let base: CGFloat = 50
        #endif
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
                .background(isSelected ? Theme.accent : Theme.surfaceHighlight)
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
            if viewModel.hasActiveFilters || !viewModel.channelSearchText.isEmpty {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.textTertiary)
                Text("No channels match filters")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Button("Clear Filters") {
                    viewModel.selectedGroupId = nil
                    viewModel.selectedProfileId = nil
                    viewModel.channelSearchText = ""
                }
                .buttonStyle(AccentButtonStyle())
            } else {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var currentTimelineHour: Date?
    @State private var scrollTargetId: String?
    @State private var gridHorizontalOffset: CGFloat = 0
    #if os(iOS)
    @State private var lastScrollDirectionChangeY: CGFloat = 0
    #endif
    @Environment(\.scenePhase) private var scenePhase

    #if os(tvOS)
    // tvOS manual focus tracking (like Rivulet approach)
    @FocusState private var gridHasFocus: Bool
    @State private var isTVSearchFieldFocused = false
    @State private var requestTVSearchKeyboard = false
    @State private var focusedRow: Int = 0
    @State private var focusedColumn: Int = 0
    @State private var scrollTopRow: Int = 0
    @State private var focusedHeaderItem: TVGuideHeaderItem = .search
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
    @State private var scrollViewHeight: CGFloat = 0

    private var iOSMacOSGuideContent: some View {
        // Main grid — single LazyVStack for guaranteed lazy rendering
        // Channel cells pinned to left edge by counteracting horizontal scroll
        ScrollViewReader { programProxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                LazyVStack(spacing: 1) {
                    // Invisible scroll anchors for scroll-to-time
                    HStack(spacing: 0) {
                        Color.clear.frame(width: channelWidth, height: 1)
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

                    #if !os(tvOS)
                    // Top padding so first row isn't behind the floating date pill + filter panel
                    Color.clear.frame(height: guideTopPadding)
                    #endif

                    ForEach(viewModel.channels) { channel in
                        ZStack(alignment: .leading) {
                            // Programs (scroll with content)
                            HStack(spacing: 0) {
                                Color.clear.frame(width: channelWidth, height: rowHeight)
                                programsRow(channel)
                                    .frame(height: rowHeight)
                                    .background(Theme.surface)
                            }

                            // Channel cell pinned to visible left edge (after safe area)
                            channelCell(channel)
                                .frame(width: channelWidth, height: rowHeight)
                                .offset(x: gridHorizontalOffset + rootLeadingSafeArea)
                                .zIndex(1)
                        }
                    }

                    #if os(macOS)
                    // Bottom padding so last row isn't behind the floating search bar
                    Color.clear.frame(height: 60)
                    #endif
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
            #if os(iOS)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { old, new in
                let delta = new - old
                if delta > 5 && !appState.isBottomBarHidden {
                    // Scrolling down — hide immediately
                    withAnimation(.easeInOut(duration: 0.25)) {
                        appState.isBottomBarHidden = true
                    }
                    lastScrollDirectionChangeY = new
                } else if delta < -5 && appState.isBottomBarHidden {
                    // Scrolling up — only show after sustained upward scroll
                    let upDistance = lastScrollDirectionChangeY - new
                    if upDistance > 80 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            appState.isBottomBarHidden = false
                        }
                    }
                }
                // Track where direction last changed to down
                if delta > 5 {
                    lastScrollDirectionChangeY = new
                }
            }
            #endif
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
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                viewModel.scrollToNow()
                updateScrollTarget()
            }
        }
    }
    #endif

    private let filterRowIndex = -1

    #if os(tvOS)
    private enum TVGuideHeaderItem: Int, CaseIterable {
        case previousDay
        case nextDay
        case search
        #if DISPATCHERPVR
        case group
        case profile
        #endif
    }

    private var tvHeaderItems: [TVGuideHeaderItem] {
        var items: [TVGuideHeaderItem] = [.previousDay, .nextDay, .search]
        #if DISPATCHERPVR
        items.append(contentsOf: [.group, .profile])
        #endif
        return items
    }

    #if DISPATCHERPVR
    private enum TVGuideDrawerKind {
        case group
        case profile
    }

    private struct TVGuideDrawerItem: Identifiable {
        let id: String
        let label: String
        let value: Int?
    }

    @State private var headerDrawerKind: TVGuideDrawerKind? = nil
    @State private var drawerSelectionIndex: Int = 0

    private var isHeaderDrawerOpen: Bool { headerDrawerKind != nil }

    private var currentDrawerItems: [TVGuideDrawerItem] {
        switch headerDrawerKind {
        case .group:
            let populatedGroups = epgCache.channelGroups.filter { group in
                epgCache.visibleChannels.contains { $0.groupId == group.id }
            }
            return [TVGuideDrawerItem(id: "group-all", label: "All Groups", value: nil)] +
                   populatedGroups.map { TVGuideDrawerItem(id: "group-\($0.id)", label: $0.name, value: $0.id) }
        case .profile:
            return [TVGuideDrawerItem(id: "profile-all", label: "All Profiles", value: nil)] +
                   epgCache.channelProfiles.map { TVGuideDrawerItem(id: "profile-\($0.id)", label: $0.name, value: $0.id) }
        case .none:
            return []
        }
    }
    #endif

    private var tvOSGuideContent: some View {
        GeometryReader { geometry in
            let gridWidth = geometry.size.width - channelWidth
            let pxPerMinute = gridWidth / visibleMinutes
            let filterRowHeight: CGFloat = 70
            #if DISPATCHERPVR
            let drawerContentHeight = 60 + CGFloat(currentDrawerItems.count) * 52
            let drawerHeight: CGFloat = isHeaderDrawerOpen ? min(320, max(170, drawerContentHeight)) : 0
            #else
            let drawerHeight: CGFloat = 0
            #endif

            // Grid — manual offset driven by scrollTopRow (keep-in-view scrolling)
            let totalRows = viewModel.channels.count
            let visibleRows = Int((geometry.size.height - filterRowHeight - drawerHeight) / rowHeight)
            let scrollOffset = CGFloat(scrollTopRow) * rowHeight

            // Virtualization: only render visible rows + buffer
            let buffer = 3
            let firstRow = max(0, scrollTopRow - buffer)
            let lastRow = min(totalRows - 1, scrollTopRow + visibleRows - 1 + buffer)

            VStack(spacing: 0) {
                // Filter row (row -1)
                tvOSFilterRow(
                    isFocused: gridHasFocus && focusedRow == filterRowIndex,
                    focusedItem: focusedHeaderItem
                )
                .frame(height: filterRowHeight)
                #if DISPATCHERPVR
                if isHeaderDrawerOpen {
                    tvOSHeaderDrawer
                        .frame(height: drawerHeight)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                #endif

                // Channel rows
                VStack(spacing: 0) {
                    if totalRows > 0 {
                        Color.clear.frame(height: CGFloat(firstRow) * rowHeight)
                        ForEach(firstRow...lastRow, id: \.self) { rowIndex in
                            tvOSChannelRow(
                                channel: viewModel.channels[rowIndex],
                                rowIndex: rowIndex,
                                gridWidth: gridWidth,
                                pxPerMinute: pxPerMinute
                            )
                            .id(viewModel.channels[rowIndex].id)
                        }
                        Color.clear.frame(height: CGFloat(max(0, totalRows - 1 - lastRow)) * rowHeight)
                    }
                }
                .offset(y: -scrollOffset)
                .animation(.easeInOut(duration: 0.15), value: scrollTopRow)
            }
            .contentShape(Rectangle())
            .focusable(true)
            .onChange(of: focusedRow) { _, newRow in
                guard newRow >= 0 else { return }
                // Only scroll when focused row would be outside visible area
                let maxTopRow = max(0, viewModel.channels.count - visibleRows)
                if newRow < scrollTopRow {
                    scrollTopRow = max(0, newRow)
                } else if newRow >= scrollTopRow + visibleRows {
                    scrollTopRow = min(maxTopRow, newRow - visibleRows + 1)
                }
            }
            .focused($gridHasFocus)
            .onTapGesture {
                handleTVSelect()
            }
            .onMoveCommand { direction in
                handleTVNavigation(direction)
            }
            .onPlayPauseCommand {
                handleTVSelect()
            }
        }
        .onChange(of: viewModel.selectedDate) {
            // Reset grid time window when date changes
            let calendar = Calendar.current
            if calendar.isDateInToday(viewModel.selectedDate) {
                // Today: start from current time rounded to 30 min
                let now = Date()
                let minute = calendar.component(.minute, from: now)
                let roundedMinute = (minute / 30) * 30
                guideStartTime = calendar.date(bySettingHour: calendar.component(.hour, from: now),
                                               minute: roundedMinute, second: 0, of: now) ?? now
            } else {
                // Other days: start from midnight
                guideStartTime = calendar.startOfDay(for: viewModel.selectedDate)
            }
            timeOffset = 0
            focusedRow = 0
            focusedColumn = 0
            scrollTopRow = 0
            endTVSearchEditing()
            #if DISPATCHERPVR
            closeHeaderDrawer()
            #endif
        }
    }

    private func tvOSChannelRow(channel: Channel, rowIndex: Int, gridWidth: CGFloat, pxPerMinute: CGFloat) -> some View {
        let isRowFocused = gridHasFocus && rowIndex == focusedRow
        let programs = tvOSVisiblePrograms(for: channel)

        return HStack(spacing: 0) {
            // Channel cell
            tvOSChannelCell(channel: channel, isSelected: isRowFocused)

            // Programs row
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.ultraThinMaterial)

                if programs.isEmpty {
                    // Show channel name as tappable placeholder so user can still play
                    let isFocused = isRowFocused && focusedColumn == 0
                    Text(channel.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(isFocused ? Theme.accent.opacity(0.3) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isFocused ? Theme.accent : Color.clear, lineWidth: 2)
                        )
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
        CachedAsyncImage(url: try? client.channelIconURL(channelId: channel.id)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            Image(systemName: "tv")
                .font(.title)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.leading, 40)
        .padding(.trailing, 10)
        .frame(width: channelWidth, height: rowHeight)
        .background(.ultraThinMaterial)
    }

    private func tvOSProgramCell(program: Program, isFocused: Bool, gridWidth: CGFloat, pxPerMinute: CGFloat) -> some View {
        let (xPos, cellWidth) = tvOSProgramPosition(program: program, pxPerMinute: pxPerMinute)
        let isAiring = program.isCurrentlyAiring
        let isScheduled = viewModel.isScheduledRecording(program)
        let isRecording = isScheduled && isAiring && viewModel.recordingStatus(program) == .recording

        let bgColor: Color = {
            if isRecording {
                return Theme.recording.opacity(0.3)
            } else if isAiring {
                return Theme.guideNowPlaying
            } else {
                return Theme.surfaceElevated
            }
        }()

        let showSport = cellWidth > 200
        let sportIconSize = rowHeight - 10 - 16 // cell height minus padding

        return ZStack {
            HStack(spacing: 6) {
                if showSport, let sport = SportDetector.detect(from: program) {
                    SportIconView(sport: sport, size: sportIconSize)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(program.cleanName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Text("\(program.startDate, format: .dateTime.hour().minute()) - \(program.endDate, format: .dateTime.hour().minute())")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // "New" green band on top-right
            if program.isNew {
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

            // Scheduled/recording red band on bottom-right
            if isScheduled {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Theme.recording
                            .frame(width: 8, height: 24)
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 4,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: 10,
                                topTrailingRadius: 0
                            ))
                            .opacity(isRecording ? 1.0 : 0.6)
                    }
                }
            }
        }
        .frame(width: max(cellWidth - 4, 80), height: rowHeight - 10, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(bgColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isFocused ? Theme.accent.opacity(0.95) : Color.clear, lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: isFocused ? Theme.accent.opacity(0.22) : .clear, radius: 10, x: 0, y: 1)
        .scaleEffect(isFocused ? 1.015 : 1.0, anchor: .leading)
        .zIndex(isFocused ? 1 : 0)
        .animation(.easeInOut(duration: 0.14), value: isFocused)
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
        // Use programs(for:) instead of visiblePrograms(for:) to avoid the
        // ViewModel's time-based filter which uses live Date() and can desync
        // from our frozen guideStartTime, causing cells to disappear.
        let programs = viewModel.programs(for: channel)
        return programs.filter { program in
            program.endDate > visibleStart && program.startDate < visibleEnd
        }
    }

    // MARK: - tvOS Filter Bar

    /// Filter row rendered as the first row in the grid (focusedRow == -1)
    private func tvOSFilterRow(isFocused: Bool, focusedItem: TVGuideHeaderItem) -> some View {
        HStack(spacing: Theme.spacingLG) {
            // Date
            tvOSHeaderField(
                imageName: "chevron.left",
                isFocused: isFocused && focusedItem == .previousDay,
                isEnabled: !viewModel.isOnToday
            )

            Text(viewModel.selectedDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.headline)
                .foregroundStyle(isFocused ? .white : Theme.textPrimary)

            tvOSHeaderField(
                imageName: "chevron.right",
                isFocused: isFocused && focusedItem == .nextDay,
                isEnabled: true
            )

            Rectangle().fill(Theme.surfaceHighlight).frame(width: 1, height: 30)

            // Search / active filter
            tvOSSearchField(isFocused: isFocused && focusedItem == .search)

            #if DISPATCHERPVR
            tvOSDispatcharrField(
                icon: "folder.fill",
                title: "Group",
                value: selectedGroupLabel,
                isFocused: isFocused && focusedItem == .group
            )
            tvOSDispatcharrField(
                icon: "person.fill",
                title: "Profile",
                value: selectedProfileLabel,
                isFocused: isFocused && focusedItem == .profile
            )
            #endif

            Spacer()
        }
        .padding(.horizontal, Theme.spacingLG)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? Theme.surfaceHighlight : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private var selectedGroupLabel: String {
        if let groupId = viewModel.selectedGroupId,
           let group = epgCache.channelGroups.first(where: { $0.id == groupId }) {
            return group.name
        }
        return "All Groups"
    }

    private var selectedProfileLabel: String {
        if let profileId = viewModel.selectedProfileId,
           let profile = epgCache.channelProfiles.first(where: { $0.id == profileId }) {
            return profile.name
        }
        return "All Profiles"
    }

    private func tvOSSearchField(isFocused: Bool) -> some View {
        let isActive = isFocused || isTVSearchFieldFocused
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isActive ? Color(white: 0.1) : Theme.textTertiary)
            TVImmediateSearchField(
                text: $viewModel.channelSearchText,
                placeholder: "Search channels...",
                requestFocus: $requestTVSearchKeyboard,
                useFocusedStyle: isActive,
                onFocusChange: { focused in
                    isTVSearchFieldFocused = focused
                    if !focused {
                        requestTVSearchKeyboard = false
                        DispatchQueue.main.async {
                            gridHasFocus = true
                        }
                        clampFocusedRowToChannels()
                    }
                }
            )
            .frame(height: 36)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.white : Theme.surfaceElevated.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.clear : Theme.surfaceHighlight, lineWidth: 1)
        )
        .scaleEffect(isActive ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.14), value: isActive)
    }

    private func beginTVSearchEditing() {
        gridHasFocus = false
        requestTVSearchKeyboard = true
    }

    private func endTVSearchEditing() {
        requestTVSearchKeyboard = false
        isTVSearchFieldFocused = false
        DispatchQueue.main.async {
            gridHasFocus = true
        }
    }

    private func tvOSDispatcharrField(
        icon: String,
        title: String,
        value: String,
        isFocused: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text("\(title): \(value)")
                .lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(
            isFocused
            ? Color(white: 0.1)
            : (value.hasPrefix("All ") ? Theme.textTertiary : Theme.accent)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? Color.white : Theme.surfaceElevated.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Color.clear : Theme.surfaceHighlight, lineWidth: 1)
        )
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.14), value: isFocused)
    }

    #if DISPATCHERPVR
    private var tvOSHeaderDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headerDrawerKind == .group ? "Select Group" : "Select Profile")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(currentDrawerItems.enumerated()), id: \.element.id) { index, item in
                        let isSelected = index == drawerSelectionIndex
                        HStack(spacing: 10) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.accent)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Text(item.label)
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected ? Theme.surfaceElevated : Theme.surface.opacity(0.3))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Theme.accent : Theme.surfaceHighlight.opacity(0.5), lineWidth: isSelected ? 2 : 1)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, Theme.spacingLG)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
    #endif

    private func tvOSHeaderField(
        imageName: String,
        isFocused: Bool,
        isEnabled: Bool
    ) -> some View {
        Image(systemName: imageName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(
                isEnabled
                ? (isFocused ? Color(white: 0.1) : Theme.textSecondary)
                : Theme.textTertiary.opacity(0.3)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.white : Theme.surfaceElevated.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.clear : Theme.surfaceHighlight, lineWidth: 1)
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.14), value: isFocused)
    }

    private func clampFocusedRowToChannels() {
        focusedRow = 0
        scrollTopRow = 0
        focusedColumn = 0
    }

    #if DISPATCHERPVR
    private func openHeaderDrawer(_ kind: TVGuideDrawerKind) {
        headerDrawerKind = kind
        let selectedValue: Int? = (kind == .group) ? viewModel.selectedGroupId : viewModel.selectedProfileId
        if let idx = currentDrawerItems.firstIndex(where: { $0.value == selectedValue }) {
            drawerSelectionIndex = idx
        } else {
            drawerSelectionIndex = 0
        }
    }

    private func closeHeaderDrawer() {
        headerDrawerKind = nil
    }

    private func applyDrawerSelection() {
        guard let kind = headerDrawerKind, currentDrawerItems.indices.contains(drawerSelectionIndex) else { return }
        let selected = currentDrawerItems[drawerSelectionIndex]
        switch kind {
        case .group:
            viewModel.selectedGroupId = selected.value
        case .profile:
            viewModel.selectedProfileId = selected.value
        }
        clampFocusedRowToChannels()
        closeHeaderDrawer()
    }

    private func handleHeaderDrawerNavigation(_ direction: MoveCommandDirection) {
        guard !currentDrawerItems.isEmpty else { return }
        switch direction {
        case .up:
            drawerSelectionIndex = max(0, drawerSelectionIndex - 1)
        case .down:
            drawerSelectionIndex = min(currentDrawerItems.count - 1, drawerSelectionIndex + 1)
        case .left, .right:
            closeHeaderDrawer()
        @unknown default:
            break
        }
    }
    #endif



    private func handleTVNavigation(_ direction: MoveCommandDirection) {
        #if DISPATCHERPVR
        if isHeaderDrawerOpen {
            handleHeaderDrawerNavigation(direction)
            return
        }
        #endif

        if isTVSearchFieldFocused {
            endTVSearchEditing()
            if direction == .down {
                clampFocusedRowToChannels()
                return
            }
        }

        let channels = viewModel.channels

        switch direction {
        case .up:
            if focusedRow == filterRowIndex {
                onRequestNavBarFocus?()
            } else if focusedRow == 0 {
                // Move up to filter row
                focusedRow = filterRowIndex
                focusedHeaderItem = focusedColumn == 0 ? .nextDay : .search
            } else {
                focusedRow -= 1
                clampColumn()
            }
        case .down:
            if focusedRow == filterRowIndex {
                // Move from filter row to first channel
                focusedRow = 0
            } else if focusedRow < channels.count - 1 {
                focusedRow += 1
                clampColumn()
            }
        case .left:
            if focusedRow == filterRowIndex {
                moveHeaderFocusLeft()
                return
            }
            guard focusedRow >= 0, !channels.isEmpty else { return }
            if focusedColumn > 0 {
                focusedColumn -= 1
            } else if timeOffset > 0 {
                // Scroll back in time — focus on last program in new window
                timeOffset -= 1
                let newPrograms = tvOSVisiblePrograms(for: channels[focusedRow])
                focusedColumn = newPrograms.isEmpty ? 0 : newPrograms.count - 1
            }
        case .right:
            if focusedRow == filterRowIndex {
                moveHeaderFocusRight()
                return
            }
            guard focusedRow >= 0, !channels.isEmpty else { return }
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

    private func moveHeaderFocusLeft() {
        guard let currentIndex = tvHeaderItems.firstIndex(of: focusedHeaderItem) else { return }
        focusedHeaderItem = tvHeaderItems[max(0, currentIndex - 1)]
    }

    private func moveHeaderFocusRight() {
        guard let currentIndex = tvHeaderItems.firstIndex(of: focusedHeaderItem) else { return }
        focusedHeaderItem = tvHeaderItems[min(tvHeaderItems.count - 1, currentIndex + 1)]
    }

    private func handleTVSelect() {
        #if DISPATCHERPVR
        if isHeaderDrawerOpen {
            applyDrawerSelection()
            return
        }
        #endif
        if isTVSearchFieldFocused {
            endTVSearchEditing()
            clampFocusedRowToChannels()
            return
        }
        if focusedRow == filterRowIndex {
            selectFocusedHeaderItem()
            return
        }
        selectFocusedProgram()
    }

    private func selectFocusedHeaderItem() {
        switch focusedHeaderItem {
        case .previousDay:
            guard !viewModel.isOnToday else { return }
            viewModel.previousDay()
            Task { await viewModel.navigateToDate(using: client) }
        case .nextDay:
            endTVSearchEditing()
            viewModel.nextDay()
            Task { await viewModel.navigateToDate(using: client) }
        case .search:
            beginTVSearchEditing()
        #if DISPATCHERPVR
        case .group:
            endTVSearchEditing()
            openHeaderDrawer(.group)
        case .profile:
            endTVSearchEditing()
            openHeaderDrawer(.profile)
        #endif
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

        // No EPG data — play channel live
        guard focusedColumn < programs.count else {
            playLiveChannel(channel)
            return
        }

        let program = programs[focusedColumn]
        selectedProgramDetail = (program: program, channel: channel)
    }

    #endif


    @ViewBuilder
    private func channelCell(_ channel: Channel) -> some View {
        #if os(tvOS)
        // tvOS: non-interactive channel icon - logo fills the cell
        CachedAsyncImage(url: try? client.channelIconURL(channelId: channel.id)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            ProgressView()
                .scaleEffect(0.5)
        }
        .padding(Theme.spacingSM)
        .frame(width: channelWidth, height: rowHeight)
        .background(Theme.channelColumnBackground)
        #else
        // iOS/macOS: tappable to play live
        Button {
            playLiveChannel(channel)
        } label: {
            CachedAsyncImage(url: try? client.channelIconURL(channelId: channel.id)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                ProgressView()
                    .scaleEffect(0.5)
            }
            .frame(width: Theme.iconSize, height: Theme.iconSize)
            .frame(width: channelWidth, height: rowHeight)
            .background(Theme.channelColumnBackground)
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
                .frame(width: hourWidth * CGFloat(viewModel.hoursToShow.count))

            if programs.isEmpty {
                // Show channel name as placeholder so user can still tap to play
                Button {
                    playLiveChannel(channel)
                } label: {
                    Text(channel.name)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, Theme.spacingMD)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            // Program cells
            ForEach(programs) { program in
                let isScheduled = viewModel.isScheduledRecording(program)
                let status = viewModel.recordingStatus(program)
                let isRecording = isScheduled && program.isCurrentlyAiring && status == .recording
                let matchesKeywords = viewModel.keywordMatchedProgramIds.contains(program.id)
                let sport = viewModel.detectedSport(for: program)
                // Calculate leading padding for live programs - push text to visible left edge (scroll target)
                let leadingPad = GuideScrollHelper.calculateLeadingPadding(
                    programStart: max(program.startDate, timelineStart),
                    scrollTarget: scrollTarget,
                    hourWidth: hourWidth,
                    isCurrentlyAiring: program.isCurrentlyAiring
                )

                Button {
                    #if os(tvOS)
                    selectedProgramDetail = (program: program, channel: channel)
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
                #else
                .buttonStyle(.plain)
                .contextMenu {
                    if program.isCurrentlyAiring, let recId = viewModel.activeRecordingId(for: program, channelId: channel.id) {
                        #if !DISPATCHERPVR
                        let canPlay = UserPreferences.load().currentGPUAPI == .pixelbuffer
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
                            Label(canPlay ? "Watch from Beginning" : "Watch from Beginning (requires PixelBuffer)", systemImage: "play.fill")
                        }
                        .disabled(!canPlay)
                        #endif

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
                                    try? await client.scheduleRecording(program: program, channel: channel)
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
        .frame(width: hourWidth * CGFloat(viewModel.hoursToShow.count), height: rowHeight)
    }

    @ViewBuilder
    private func nowIndicator(timelineStart: Date) -> some View {
        let now = Date()
        if now >= timelineStart && now < timelineStart.addingTimeInterval(Double(viewModel.hoursToShow.count) * 3600) {
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

        // Store scroll target for text padding calculation
        let scrollTargetDate = GuideScrollHelper.calculateScrollTarget(currentTime: isToday ? now : viewModel.timelineStart)
        currentTimelineHour = scrollTargetDate

        // On today, the timeline already starts at the current hour — no scroll needed.
        // For other days, scroll to start of day.
        guard !isToday else {
            scrollTargetId = nil
            return
        }

        let targetTime = viewModel.timelineStart
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

#if os(tvOS)
private struct TVImmediateSearchField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var requestFocus: Bool
    var useFocusedStyle: Bool
    var onFocusChange: (Bool) -> Void

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TVImmediateSearchField

        init(parent: TVImmediateSearchField) {
            self.parent = parent
        }

        @objc func textDidChange(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocusChange(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onFocusChange(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.text = text
        field.textColor = UIColor.white
        field.tintColor = UIColor.white
        field.borderStyle = .none
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
        field.adjustsFontSizeToFitWidth = true
        field.minimumFontSize = 12
        field.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        uiView.placeholder = placeholder
        uiView.textColor = useFocusedStyle ? UIColor(white: 0.1, alpha: 1.0) : UIColor.white
        uiView.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: useFocusedStyle
                    ? UIColor(white: 0.35, alpha: 1.0)
                    : UIColor(white: 0.62, alpha: 1.0)
            ]
        )

        if requestFocus {
            if !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}
#endif


#Preview {
    GuideView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .environmentObject(EPGCache())
        #if os(iOS)
        .environmentObject(GuideViewModel())
        #endif
        .preferredColorScheme(.dark)
}
