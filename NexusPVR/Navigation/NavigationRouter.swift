//
//  NavigationRouter.swift
//  nextpvr-apple-client
//
//  Platform-adaptive navigation
//

import SwiftUI

// MARK: - Nav Bar Focus Environment Key

#if os(tvOS)
private struct RequestNavBarFocusKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var requestNavBarFocus: () -> Void {
        get { self[RequestNavBarFocusKey.self] }
        set { self[RequestNavBarFocusKey.self] = newValue }
    }
}
#endif

// MARK: - iOS Sidebar Toggle Environment Key

#if os(iOS)
private struct OpenSidebarKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openSidebar: () -> Void {
        get { self[OpenSidebarKey.self] }
        set { self[OpenSidebarKey.self] = newValue }
    }
}

/// ViewModifier that injects the sidebar menu button into a NavigationStack toolbar
struct SidebarMenuToolbar: ViewModifier {
    @Environment(\.openSidebar) private var openSidebar
    @EnvironmentObject private var appState: AppState

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            openSidebar()
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .overlay(alignment: .topTrailing) {
                                sidebarButtonBadge
                            }
                    }
                    .accessibilityIdentifier("nav-expand-button")
                }
            }
    }

    @ViewBuilder
    private var sidebarButtonBadge: some View {
        let hasRecordingBadge = appState.recordingsHasActive
        #if DISPATCHERPVR
        let hasStatsBadge = appState.activeStreamCount > 0 || appState.hasM3UErrors
        #else
        let hasStatsBadge = false
        #endif
        if hasRecordingBadge || hasStatsBadge {
            Circle()
                .fill(Theme.recording)
                .frame(width: 10, height: 10)
                .offset(x: 2, y: -2)
        }
    }
}

extension View {
    func sidebarMenuToolbar() -> some View {
        modifier(SidebarMenuToolbar())
    }
}
#endif

struct NavigationRouter: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: PVRClient

    var body: some View {
        Group {
            #if os(macOS)
            MacOSNavigation()
            #elseif os(tvOS)
            TVOSNavigation()
            #else
            IOSNavigation()
            #endif
        }
        .task {
            if appState.userLevel >= 1 {
                #if !TOPSHELF_EXTENSION
                await appState.refreshRecordingsActivity(client: client)
                appState.startRecordingsActivityPolling(client: client)
                #endif
                #if DISPATCHERPVR
                appState.startStreamCountPolling(client: client)
                #endif
            }
        }
        .onChange(of: appState.userLevel) { _, level in
            guard level >= 1 else {
                #if !TOPSHELF_EXTENSION
                appState.stopRecordingsActivityPolling()
                appState.activeRecordingCount = 0
                #endif
                #if DISPATCHERPVR
                appState.stopStreamCountPolling()
                appState.activeStreamCount = 0
                appState.hasM3UErrors = false
                #endif
                return
            }
            #if !TOPSHELF_EXTENSION
            Task { await appState.refreshRecordingsActivity(client: client) }
            appState.startRecordingsActivityPolling(client: client)
            #endif
            #if DISPATCHERPVR
            appState.startStreamCountPolling(client: client)
            #endif
        }
        .onDisappear {
            #if !TOPSHELF_EXTENSION
            appState.stopRecordingsActivityPolling()
            #endif
            #if DISPATCHERPVR
            appState.stopStreamCountPolling()
            #endif
        }
        #if !TOPSHELF_EXTENSION
        .onReceive(NotificationCenter.default.publisher(for: .recordingsDidChange)) { _ in
            Task { await appState.refreshRecordingsActivity(client: client) }
        }
        #endif
    }
}

// MARK: - iOS/iPadOS Navigation

#if os(iOS)
struct IOSNavigation: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var epgCache: EPGCache
    @StateObject private var guideViewModel = GuideViewModel()

    @State private var isSidebarOpen = false
    @State private var searchText = ""
    @State private var showSearchDropdown = false
    @State private var channelMatchCount = 0
    @State private var programMatchCount = 0
    @State private var matchingGroups: [ChannelGroup] = []
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var lastSearchedText = ""
    @FocusState private var isSearchFocused: Bool

    private var sidebarWidth: CGFloat {
        260 + Self.windowSafeArea.leading
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab content — each child has its own NavigationStack.
            // .sidebarMenuToolbar() injects the hamburger button via .toolbar.
            // Apple's toolbar system handles Dynamic Island / safe areas automatically.
            Group {
                switch appState.selectedTab {
                case .guide:
                    NavigationStack {
                        GuideView()
                            .environmentObject(guideViewModel)
                            .sidebarMenuToolbar()
                            .toolbar {
                                ToolbarItem(placement: .principal) {
                                    iOSGuideToolbarContent
                                }
                            }
                            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                            .toolbarBackground(.visible, for: .navigationBar)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                case .topics:
                    if appState.showingKeywordsEditor {
                        NavigationStack {
                            KeywordsEditorView()
                                .sidebarMenuToolbar()
                                .navigationBarTitleDisplayMode(.inline)
                                .onDisappear {
                                    appState.topicKeywords = UserPreferences.load().keywords
                                    Task { await computeTopicMatchCounts() }
                                }
                        }
                    } else {
                        TopicsView()
                    }
                case .calendar:
                    CalendarTabView()
                case .search:
                    SearchView()
                case .recordings:
                    RecordingsListView()
                #if DISPATCHERPVR
                case .stats:
                    // StatsView has no NavigationStack — wrap it
                    NavigationStack {
                        StatsView()
                            .sidebarMenuToolbar()
                            .navigationTitle("Status")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                #endif
                case .settings:
                    SettingsView()
                }
            }
            .environment(\.openSidebar, {
                isSidebarOpen = true
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Floating bottom bar: search / topic picker / recordings filter
            if !appState.isBottomBarHidden || appState.selectedTab != .guide {
                VStack(spacing: 6) {
                    if showSearchDropdown {
                        searchDropdown
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .padding(.horizontal, Theme.spacingMD)
                    }

                    HStack(spacing: 10) {
                        if appState.selectedTab == .guide || appState.selectedTab == .search {
                            searchBar
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.spacingMD)
                }
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showSearchDropdown)
            }

            // Dismiss search dropdown
            if showSearchDropdown {
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearchDropdown = false
                            isSearchFocused = false
                        }
                    }
            }
        }
        .background(Theme.background)
        .overlay {
            if isSidebarOpen {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isSidebarOpen = false
                        }
                    }
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .leading) {
            HStack(spacing: 0) {
                sidebarInner(safeArea: Self.windowSafeArea)
                    .frame(width: sidebarWidth)
                    .background(Theme.surface)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: Theme.cornerRadiusLG,
                            topTrailingRadius: Theme.cornerRadiusLG
                        )
                    )
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 5, y: 0)
                Spacer()
            }
            .offset(x: isSidebarOpen ? 0 : -sidebarWidth - 20)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSidebarOpen)
            .ignoresSafeArea()
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if !isSidebarOpen && value.startLocation.x < 30 && value.translation.width > 60 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isSidebarOpen = true
                        }
                    }
                    if isSidebarOpen && value.translation.width < -60 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isSidebarOpen = false
                        }
                    }
                }
        )
        .fullScreenCover(isPresented: $appState.isShowingPlayer) {
            if let url = appState.currentlyPlayingURL {
                PlayerView(
                    url: url,
                    title: appState.currentlyPlayingTitle ?? "",
                    recordingId: appState.currentlyPlayingRecordingId,
                    resumePosition: appState.currentlyPlayingResumePosition,
                    isRecordingInProgress: appState.currentlyPlayingIsRecordingInProgress
                )
                .statusBarHidden()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreFromPiP)) { _ in
            appState.isShowingPlayer = true
        }
        .onAppear {
            appState.topicKeywords = UserPreferences.load().keywords
        }
        .onChange(of: appState.showingKeywordsEditor) {
            if !appState.showingKeywordsEditor {
                appState.topicKeywords = UserPreferences.load().keywords
                Task { await computeTopicMatchCounts() }
            }
        }
        .onChange(of: epgCache.isFullyLoaded) {
            if epgCache.isFullyLoaded {
                Task { await computeTopicMatchCounts() }
            }
        }
        .onChange(of: searchText) { oldValue, newValue in
            searchDebounceTask?.cancel()
            if appState.selectedTab == .search {
                Task { appState.searchQuery = newValue }
                showSearchDropdown = false
                return
            }
            if newValue.count < 2 {
                showSearchDropdown = false
                channelMatchCount = 0
                programMatchCount = 0
                matchingGroups = []
                lastSearchedText = ""
                return
            }
            guard newValue != lastSearchedText else { return }
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let channels = epgCache.filteredChannels(matching: newValue).count
                let programs = await epgCache.searchProgramsCount(query: newValue)
                guard !Task.isCancelled else { return }
                channelMatchCount = channels
                programMatchCount = programs
                #if DISPATCHERPVR
                let query = newValue.lowercased()
                let groupsWithChannels = epgCache.channelGroups.filter { group in
                    group.name.lowercased().contains(query) &&
                    epgCache.visibleChannels.contains { $0.groupId == group.id }
                }
                matchingGroups = groupsWithChannels
                #endif
                lastSearchedText = newValue
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearchDropdown = true
                }
            }
        }
        .onChange(of: appState.selectedTab) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showSearchDropdown = false
                appState.isBottomBarHidden = false
            }
            // Reset editor flag when leaving topics
            if appState.selectedTab != .topics {
                appState.showingKeywordsEditor = false
            }
        }
        .background {
            Button("") {
                if appState.selectedTab == .guide || appState.selectedTab == .search {
                    isSearchFocused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                    }
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
    }

    // MARK: - Topic Match Counts

    private func computeTopicMatchCounts() async {
        let keywords = appState.topicKeywords
        guard !keywords.isEmpty, epgCache.isFullyLoaded else { return }
        let matches = await epgCache.matchingPrograms(keywords: keywords)
        var counts: [String: Int] = [:]
        for match in matches where match.matchedKeyword != MatchingProgram.scheduledKeyword {
            counts[match.matchedKeyword, default: 0] += 1
        }
        appState.topicKeywordMatchCounts = counts
    }

    // MARK: - Guide Toolbar Content

    private var iOSGuideToolbarContent: some View {
        HStack(spacing: 6) {
            Button {
                guideViewModel.previousDay()
                Task { await guideViewModel.navigateToDate(using: client) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(guideViewModel.isOnToday ? Theme.textTertiary : Theme.accent)
            }
            .disabled(guideViewModel.isOnToday)

            Text(guideViewModel.selectedDate, format: .dateTime.month(.abbreviated).day())
                .font(.subheadline.weight(.medium))

            Button {
                guideViewModel.nextDay()
                Task { await guideViewModel.navigateToDate(using: client) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            #if DISPATCHERPVR
            if !epgCache.channelProfiles.isEmpty || epgCache.channelGroups.contains(where: { group in
                epgCache.visibleChannels.contains { $0.groupId == group.id }
            }) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        guideViewModel.showFilters.toggle()
                    }
                } label: {
                    Image(systemName: guideViewModel.hasActiveFilters
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(guideViewModel.hasActiveFilters ? Theme.accent : Theme.textPrimary)
                }
            }
            #endif
        }
    }

    // MARK: - Window Safe Area (read from UIKit)

    private static var windowSafeArea: EdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        guard let insets = window?.safeAreaInsets else { return EdgeInsets() }
        return EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }

    // MARK: - Sidebar Content

    private func sidebarInner(safeArea: EdgeInsets) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Menu")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isSidebarOpen = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, Theme.spacingLG)
            .padding(.top, max(safeArea.top, Theme.spacingMD))
            .padding(.leading, safeArea.leading)
            .padding(.bottom, Theme.spacingMD)

            Divider().overlay(Theme.surfaceHighlight)

            // Tab items
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Tab.iOSTabs(userLevel: appState.userLevel)) { tab in
                        if tab == .recordings {
                            // Recordings header (non-tappable)
                            sidebarRow(
                                icon: tab.icon,
                                label: tab.label,
                                isSelected: false,
                                badge: { sidebarTabBadge(for: tab) }
                            )
                            .foregroundStyle(Theme.textSecondary)

                            // Sub-items
                            if appState.recordingsHasActive {
                                sidebarSubRow(label: "Active", filter: .recording)
                            }
                            sidebarSubRow(label: "Completed", filter: .completed)
                            sidebarSubRow(label: "Scheduled", filter: .scheduled)
                        } else if tab == .topics {
                            // Topics header — opens keywords editor as full view
                            Button {
                                appState.showingKeywordsEditor = true
                                appState.selectedTab = .topics
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    isSidebarOpen = false
                                }
                            } label: {
                                sidebarRow(
                                    icon: tab.icon,
                                    label: tab.label,
                                    isSelected: appState.selectedTab == .topics && appState.showingKeywordsEditor,
                                    badge: { EmptyView() }
                                )
                            }
                            .accessibilityIdentifier("tab-\(tab.rawValue)")

                            // Sub-item per keyword
                            ForEach(appState.topicKeywords, id: \.self) { keyword in
                                sidebarTopicSubRow(keyword: keyword, count: appState.topicKeywordMatchCounts[keyword])
                            }
                        } else {
                            Button {
                                appState.selectedTab = tab
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    isSidebarOpen = false
                                }
                            } label: {
                                sidebarRow(
                                    icon: tab.icon,
                                    label: tab.label,
                                    isSelected: appState.selectedTab == tab,
                                    badge: { sidebarTabBadge(for: tab) }
                                )
                            }
                            .accessibilityIdentifier("tab-\(tab.rawValue)")
                        }
                    }
                }
                .padding(.vertical, Theme.spacingSM)
                .padding(.horizontal, Theme.spacingSM)
                .padding(.leading, safeArea.leading)
            }

            Spacer()
        }
        .padding(.bottom, safeArea.bottom)
    }

    // MARK: - Sidebar Tab Badge

    // MARK: - Sidebar Row Helpers

    private func sidebarRow<Badge: View>(icon: String, label: String, isSelected: Bool, @ViewBuilder badge: () -> Badge) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 28)
            Text(label)
                .font(.body)
            Spacer()
            badge()
        }
        .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
        .padding(.horizontal, Theme.spacingLG)
        .padding(.vertical, 14)
        .background(
            isSelected ? Theme.accent.opacity(0.12) : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
    }

    private func sidebarSubRow(label: String, filter: RecordingsFilter) -> some View {
        let isSelected = appState.selectedTab == .recordings && appState.recordingsFilter == filter
        return Button {
            appState.setRecordingsFilter(filter, userInitiated: true)
            appState.selectedTab = .recordings
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isSidebarOpen = false
            }
        } label: {
            HStack(spacing: 12) {
                Color.clear.frame(width: 28) // indent to align with parent icon
                Text(label)
                    .font(.subheadline)
                Spacer()
                if filter == .recording && appState.activeRecordingCount > 0 {
                    Text("(\(appState.activeRecordingCount))")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Circle()
                        .fill(Theme.recording)
                        .frame(width: 8, height: 8)
                }
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, Theme.spacingLG)
            .padding(.leading, Theme.spacingSM)
            .padding(.vertical, 10)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        }
        .accessibilityIdentifier("recordings-filter-\(filter.rawValue)")
    }

    private func sidebarTopicSubRow(keyword: String, count: Int?) -> some View {
        let isSelected = appState.selectedTab == .topics && !appState.showingKeywordsEditor && appState.selectedTopicKeyword == keyword
        return Button {
            appState.showingKeywordsEditor = false
            appState.selectedTopicKeyword = keyword
            appState.selectedTab = .topics
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isSidebarOpen = false
            }
        } label: {
            HStack(spacing: 12) {
                Color.clear.frame(width: 28)
                Text(keyword)
                    .font(.subheadline)
                Spacer()
                if let count {
                    Text("(\(count))")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, Theme.spacingLG)
            .padding(.leading, Theme.spacingSM)
            .padding(.vertical, 10)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        }
        .accessibilityIdentifier("topic-keyword-\(keyword)")
    }

    @ViewBuilder
    private func sidebarTabBadge(for tab: Tab) -> some View {
        if tab == .recordings && appState.recordingsHasActive {
            Circle()
                .fill(Theme.recording)
                .frame(width: 10, height: 10)
        }
        #if DISPATCHERPVR
        if tab == .stats {
            HStack(spacing: 4) {
                if appState.hasM3UErrors {
                    Circle()
                        .fill(Theme.error)
                        .frame(width: 10, height: 10)
                }
                if appState.activeStreamCount > 0 {
                    Text("\(appState.activeStreamCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                }
            }
        }
        #endif
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)

            TextField("Search...", text: $searchText)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("global-search-field")
                .focused($isSearchFocused)
                .submitLabel(.search)
                .onSubmit {
                    if searchText.count >= 2 {
                        appState.searchQuery = searchText
                        appState.selectedTab = .search
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearchDropdown = false
                            isSearchFocused = false
                        }
                    }
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    showSearchDropdown = false
                    isSearchFocused = false
                    appState.guideChannelFilter = ""
                    appState.guideGroupFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    // MARK: - Search Dropdown

    private var searchDropdown: some View {
        VStack(spacing: 0) {
            Button {
                searchDebounceTask?.cancel()
                lastSearchedText = searchText
                appState.guideGroupFilter = nil
                appState.guideChannelFilter = searchText
                appState.selectedTab = .guide
                showSearchDropdown = false
                isSearchFocused = false
            } label: {
                HStack {
                    Image(systemName: "tv")
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    Text("Channels")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("(\(channelMatchCount))")
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, 12)
            }
            .disabled(channelMatchCount == 0)

            #if DISPATCHERPVR
            if !matchingGroups.isEmpty {
                Divider().overlay(Theme.surfaceHighlight)

                ForEach(matchingGroups) { group in
                    Button {
                        searchDebounceTask?.cancel()
                        lastSearchedText = searchText
                        appState.guideChannelFilter = ""
                        appState.guideGroupFilter = group.id
                        appState.selectedTab = .guide
                        showSearchDropdown = false
                        isSearchFocused = false
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24)
                            Text(group.name)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("Group")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, Theme.spacingMD)
                        .padding(.vertical, 12)
                    }
                }
            }
            #endif

            Divider().overlay(Theme.surfaceHighlight)

            Button {
                searchDebounceTask?.cancel()
                lastSearchedText = searchText
                appState.searchQuery = searchText
                appState.selectedTab = .search
                showSearchDropdown = false
                isSearchFocused = false
            } label: {
                HStack {
                    Image(systemName: "film")
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    Text("Programs")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("(\(programMatchCount))")
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, 12)
            }
            .disabled(programMatchCount == 0)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 2)
    }
}
#endif

// MARK: - tvOS Navigation

#if os(tvOS)
struct TVOSNavigation: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: PVRClient
    @State private var navBarEnabled = true
    @FocusState private var focusedTab: Tab?

    var body: some View {
        VStack(spacing: 0) {
            // Top navigation bar (TabView style)
            tvOSNavBar
                .disabled(!navBarEnabled)
                .focusSection()

            // Main content
            Group {
                switch appState.selectedTab {
                case .guide:
                    GuideView(onRequestNavBarFocus: { enableNavBar() })
                case .recordings:
                    RecordingsListView()
                case .topics, .calendar:
                    TopicsView()
                case .search:
                    SearchView()
                #if DISPATCHERPVR
                case .stats:
                    StatsView()
                #endif
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusSection()
            .environment(\.requestNavBarFocus, enableNavBar)
            .onExitCommand {
                enableNavBar()
            }
        }
        .onAppear {
            // Start with focus on nav bar
            focusedTab = appState.selectedTab
        }
        .onChange(of: focusedTab) { _, newTab in
            if let tab = newTab {
                // Change page when navigating in nav bar
                appState.selectedTab = tab
            } else {
                // When nav bar loses focus, disable it
                navBarEnabled = false
            }
        }
        .fullScreenCover(isPresented: $appState.isShowingPlayer) {
            if let url = appState.currentlyPlayingURL {
                PlayerView(
                    url: url,
                    title: appState.currentlyPlayingTitle ?? "",
                    recordingId: appState.currentlyPlayingRecordingId,
                    resumePosition: appState.currentlyPlayingResumePosition,
                    isRecordingInProgress: appState.currentlyPlayingIsRecordingInProgress
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreFromPiP)) { _ in
            appState.isShowingPlayer = true
        }
    }

    private func enableNavBar() {
        navBarEnabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedTab = appState.selectedTab
        }
    }

    private var tvOSNavBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.tvOSTabs(userLevel: appState.userLevel)) { tab in
                Button {
                    appState.selectedTab = tab
                    navBarEnabled = false
                    focusedTab = nil
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: tab.icon)
                            .font(.title3)
                        Text(tab.label)
                            .font(.headline)
                        if tab == .recordings && appState.recordingsHasActive {
                            Circle()
                                .fill(Theme.recording)
                                .frame(width: 10, height: 10)
                        }
                        #if DISPATCHERPVR
                        if tab == .stats && appState.activeStreamCount > 0 {
                            Text("\(appState.activeStreamCount)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Theme.accent)
                                .clipShape(Capsule())
                        }
                        if tab == .stats && appState.hasM3UErrors {
                            Circle()
                                .fill(Theme.error)
                                .frame(width: 10, height: 10)
                        }
                        #endif
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                }
                .buttonStyle(TVTabButtonStyle(isSelected: appState.selectedTab == tab))
                .focused($focusedTab, equals: tab)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 40)
        .background(
            LinearGradient(
                colors: [Theme.background.opacity(0.8), Theme.background.opacity(0.4), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

struct TVTabButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? .white : (isSelected ? Theme.accent : Theme.textSecondary))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? Theme.accent : Color.clear)
            )
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif

// MARK: - macOS Navigation

#if os(macOS)
struct MacOSNavigation: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var epgCache: EPGCache

    @State private var searchText = ""
    @State private var showSearchDropdown = false
    @State private var channelMatchCount = 0
    @State private var programMatchCount = 0
    @State private var matchingGroups: [ChannelGroup] = []
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var lastSearchedText = ""

    private var selectedTabBinding: Binding<Tab> {
        Binding(
            get: { appState.selectedTab },
            set: { newValue in
                Task { @MainActor in
                    appState.selectedTab = newValue
                }
            }
        )
    }

    var body: some View {
        Group {
            if appState.isShowingPlayer, let url = appState.currentlyPlayingURL {
                // Show player taking over the entire window
                PlayerView(
                    url: url,
                    title: appState.currentlyPlayingTitle ?? "",
                    recordingId: appState.currentlyPlayingRecordingId,
                    resumePosition: appState.currentlyPlayingResumePosition,
                    isRecordingInProgress: appState.currentlyPlayingIsRecordingInProgress
                )
            } else {
                // Show regular navigation with sidebar
                NavigationSplitView {
                    List(Tab.macOSTabs(userLevel: appState.userLevel), selection: selectedTabBinding) { tab in
                        HStack {
                            Label(tab.label, systemImage: tab.icon)
                            if tab == .recordings && appState.recordingsHasActive {
                                Spacer()
                                Circle()
                                    .fill(Theme.recording)
                                    .frame(width: 8, height: 8)
                            }
                            #if DISPATCHERPVR
                            if tab == .stats {
                                Spacer()
                                if appState.hasM3UErrors {
                                    Circle()
                                        .fill(Theme.error)
                                        .frame(width: 8, height: 8)
                                }
                                if appState.activeStreamCount > 0 {
                                    Text("\(appState.activeStreamCount)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.accent)
                                        .clipShape(Capsule())
                                }
                            }
                            #endif
                        }
                        .tag(tab)
                    }
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                } detail: {
                    ZStack(alignment: .bottom) {
                        // Detail content
                        Group {
                            switch appState.selectedTab {
                            case .guide:
                                GuideView()
                            case .topics:
                                TopicsView()
                            case .calendar:
                                CalendarTabView()
                            case .search:
                                SearchView()
                            case .recordings:
                                RecordingsListView()
                            #if DISPATCHERPVR
                            case .stats:
                                StatsView()
                            #endif
                            case .settings:
                                SettingsView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Dismiss layer when dropdown showing
                        if showSearchDropdown {
                            Color.black.opacity(0.01)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showSearchDropdown = false
                                    }
                                }
                        }

                        // Floating search bar + dropdown (guide tab only)
                        if appState.selectedTab == .guide {
                            VStack(spacing: 6) {
                                if showSearchDropdown {
                                    macSearchDropdown
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                                macSearchBar
                            }
                            .frame(maxWidth: 400)
                            .padding(.bottom, 12)
                            .padding(.horizontal, Theme.spacingLG)
                            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showSearchDropdown)
                        }
                    }
                }
            }
        }
        .onChange(of: searchText) { oldValue, newValue in
            searchDebounceTask?.cancel()
            if newValue.count < 2 {
                showSearchDropdown = false
                channelMatchCount = 0
                programMatchCount = 0
                matchingGroups = []
                lastSearchedText = ""
                return
            }
            guard newValue != lastSearchedText else { return }
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let channels = epgCache.filteredChannels(matching: newValue).count
                let programs = await epgCache.searchProgramsCount(query: newValue)
                guard !Task.isCancelled else { return }
                channelMatchCount = channels
                programMatchCount = programs
                #if DISPATCHERPVR
                let query = newValue.lowercased()
                let groupsWithChannels = epgCache.channelGroups.filter { group in
                    group.name.lowercased().contains(query) &&
                    epgCache.visibleChannels.contains { $0.groupId == group.id }
                }
                matchingGroups = groupsWithChannels
                #endif
                lastSearchedText = newValue
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearchDropdown = true
                }
            }
        }
        .onChange(of: appState.selectedTab) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showSearchDropdown = false
            }
        }
    }

    // MARK: - macOS Search Bar

    private var macSearchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)

            TextField("Search...", text: $searchText)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("global-search-field")
                .submitLabel(.search)
                .onSubmit {
                    if searchText.count >= 2 {
                        appState.searchQuery = searchText
                        appState.selectedTab = .search
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearchDropdown = false
                        }
                    }
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    showSearchDropdown = false
                    appState.guideChannelFilter = ""
                    appState.guideGroupFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surfaceElevated)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    // MARK: - macOS Search Dropdown

    private var macSearchDropdown: some View {
        VStack(spacing: 0) {
            // Channels row
            Button {
                searchDebounceTask?.cancel()
                lastSearchedText = searchText
                appState.guideGroupFilter = nil
                appState.guideChannelFilter = searchText
                appState.selectedTab = .guide
                showSearchDropdown = false
            } label: {
                HStack {
                    Image(systemName: "tv")
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    Text("Channels")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("(\(channelMatchCount))")
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(channelMatchCount == 0)

            #if DISPATCHERPVR
            if !matchingGroups.isEmpty {
                Divider().overlay(Theme.surfaceHighlight)

                ForEach(matchingGroups) { group in
                    Button {
                        searchDebounceTask?.cancel()
                        lastSearchedText = searchText
                        appState.guideChannelFilter = ""
                        appState.guideGroupFilter = group.id
                        appState.selectedTab = .guide
                        showSearchDropdown = false
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24)
                            Text(group.name)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("Group")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, Theme.spacingMD)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            #endif

            Divider().overlay(Theme.surfaceHighlight)

            // Programs row
            Button {
                searchDebounceTask?.cancel()
                lastSearchedText = searchText
                appState.searchQuery = searchText
                appState.selectedTab = .search
                showSearchDropdown = false
            } label: {
                HStack {
                    Image(systemName: "film")
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    Text("Programs")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("(\(programMatchCount))")
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(programMatchCount == 0)
        }
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 2)
    }
}
#endif

#Preview {
    NavigationRouter()
        .environmentObject(AppState())
        .environmentObject(PVRClient())
        .environmentObject(EPGCache())
}
