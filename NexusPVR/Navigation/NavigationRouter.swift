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
        .preferredColorScheme(.dark)
        #if DISPATCHERPVR
        .task {
            appState.startStreamCountPolling(client: client)
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

    @State private var isNavExpanded = false
    @State private var searchText = ""
    @State private var showSearchDropdown = false
    @State private var channelMatchCount = 0
    @State private var programMatchCount = 0
    @State private var matchingGroups: [ChannelGroup] = []
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var lastSearchedText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // Content area
            Group {
                switch appState.selectedTab {
                case .guide:
                    GuideView()
                case .topics:
                    TopicsView()
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
            .safeAreaInset(edge: .top) {
                Color.clear.frame(height: 16)
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 64)
            }

            // Dismiss layer when dropdown or expanded
            if showSearchDropdown || isNavExpanded {
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearchDropdown = false
                            isNavExpanded = false
                            isSearchFocused = false
                        }
                    }
            }

            // Floating nav bar
            VStack(spacing: 6) {
                // Search dropdown (above the bar)
                if showSearchDropdown {
                    searchDropdown
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .padding(.horizontal, Theme.spacingMD)
                }

                // Bottom row: menu pill (left) + search bar (right)
                HStack(spacing: 10) {
                    // Menu pill — expands to include tabs
                    menuPill

                    // Search bar — on guide and search tabs, hides when menu is expanded
                    if !isNavExpanded && (appState.selectedTab == .guide || appState.selectedTab == .search) {
                        searchBar
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                    }

                    // Topic picker — only on topics tab
                    if !isNavExpanded && appState.selectedTab == .topics && !appState.topicKeywords.isEmpty {
                        topicPicker
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                    }

                    // Recordings filter — only on recordings tab
                    if !isNavExpanded && appState.selectedTab == .recordings {
                        recordingsFilterPicker
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
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isNavExpanded)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showSearchDropdown)
        }
        .background(Theme.background)
        .fullScreenCover(isPresented: $appState.isShowingPlayer) {
            if let url = appState.currentlyPlayingURL {
                PlayerView(
                    url: url,
                    title: appState.currentlyPlayingTitle ?? "",
                    recordingId: appState.currentlyPlayingRecordingId,
                    resumePosition: appState.currentlyPlayingResumePosition
                )
            }
        }
        .onChange(of: searchText) { oldValue, newValue in
            searchDebounceTask?.cancel()
            // When on search tab, drive SearchView directly — no dropdown
            if appState.selectedTab == .search {
                appState.searchQuery = newValue
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
            // Don't re-trigger if text hasn't actually changed (spurious re-fire)
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
                    isNavExpanded = false
                }
            }
        }
        .onChange(of: appState.selectedTab) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showSearchDropdown = false
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

    // MARK: - Menu Pill (expands to show tabs)

    private var menuPill: some View {
        HStack(spacing: 0) {
            // Menu icon — visible only when collapsed
            if !isNavExpanded {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        isNavExpanded = true
                        showSearchDropdown = false
                        isSearchFocused = false
                    }
                } label: {
                    Image(systemName: appState.selectedTab.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                        .overlay(alignment: .topTrailing) {
                            tabBadge(for: appState.selectedTab)
                        }
                }
                .accessibilityIdentifier("nav-expand-button")
                .transition(.opacity)
            }

            // Tab buttons — appear when expanded
            if isNavExpanded {
                HStack(spacing: 0) {
                    ForEach(Tab.iOSTabs) { tab in
                        Button {
                            appState.selectedTab = tab
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                                isNavExpanded = false
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 17))
                                    .overlay(alignment: .topTrailing) {
                                        tabBadge(for: tab)
                                    }
                                Text(tab.label)
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(appState.selectedTab == tab ? Theme.accent : Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("tab-\(tab.rawValue)")
                    }
                }
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .leading)))
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    // MARK: - Recordings Filter Picker

    private var recordingsFilterPicker: some View {
        Menu {
            if appState.recordingsHasActive {
                Button {
                    appState.recordingsFilter = .recording
                } label: {
                    HStack {
                        Text("Recording")
                        if appState.recordingsFilter == .recording {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Button {
                appState.recordingsFilter = .completed
            } label: {
                HStack {
                    Text("Completed")
                    if appState.recordingsFilter == .completed {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button {
                appState.recordingsFilter = .scheduled
            } label: {
                HStack {
                    Text("Scheduled")
                    if appState.recordingsFilter == .scheduled {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(appState.recordingsFilter.rawValue)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
        }
        .accessibilityIdentifier("recordings-filter")
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

    // MARK: - Topic Picker

    private var topicPicker: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(appState.topicKeywords, id: \.self) { keyword in
                    Button {
                        appState.selectedTopicKeyword = keyword
                    } label: {
                        HStack {
                            Text(keyword)
                            if keyword == appState.selectedTopicKeyword {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(appState.selectedTopicKeyword.isEmpty ? "All Topics" : appState.selectedTopicKeyword)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
            }
            .accessibilityIdentifier("keyword-tabs")

            Button {
                appState.showingKeywordsEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
            }
            .background(.ultraThinMaterial)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
            .accessibilityIdentifier("edit-keywords-button")
        }
    }

    // MARK: - Search Dropdown

    private var searchDropdown: some View {
        VStack(spacing: 0) {
            // Channels row
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

                // Groups section
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

            // Programs row
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

    // MARK: - Badge

    @ViewBuilder
    private func tabBadge(for tab: Tab) -> some View {
        #if DISPATCHERPVR
        if tab == .stats {
            ZStack {
                if appState.activeStreamCount > 0 {
                    Text("\(appState.activeStreamCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                        .offset(x: 8, y: -6)
                }
                if appState.hasM3UErrors {
                    Circle()
                        .fill(Theme.error)
                        .frame(width: 8, height: 8)
                        .offset(x: appState.activeStreamCount > 0 ? -4 : 8, y: -8)
                }
            }
        }
        #endif
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
                case .topics:
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
                    resumePosition: appState.currentlyPlayingResumePosition
                )
            }
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
            ForEach(Tab.tvOSTabs) { tab in
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
                colors: [Color.black.opacity(0.8), Color.black.opacity(0.4), Color.clear],
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

    var body: some View {
        Group {
            if appState.isShowingPlayer, let url = appState.currentlyPlayingURL {
                // Show player taking over the entire window
                PlayerView(
                    url: url,
                    title: appState.currentlyPlayingTitle ?? "",
                    recordingId: appState.currentlyPlayingRecordingId,
                    resumePosition: appState.currentlyPlayingResumePosition
                )
            } else {
                // Show regular navigation with sidebar
                NavigationSplitView {
                    List(Tab.macOSTabs, selection: $appState.selectedTab) { tab in
                        HStack {
                            Label(tab.label, systemImage: tab.icon)
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
