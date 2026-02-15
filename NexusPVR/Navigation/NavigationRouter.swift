//
//  NavigationRouter.swift
//  nextpvr-apple-client
//
//  Platform-adaptive navigation
//

import SwiftUI

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
            appState.startStreamCountPolling(client: client as! DispatcherClient)
        }
        #endif
    }
}

// MARK: - iOS/iPadOS Navigation

#if os(iOS)
struct IOSNavigation: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: PVRClient

    var body: some View {
        // Content area with safe area inset for custom tab bar
        Group {
            switch appState.selectedTab {
            case .guide:
                GuideView()
            case .topics:
                TopicsView()
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
        .safeAreaInset(edge: .bottom) {
            // Custom tab bar
            HStack(spacing: 0) {
                ForEach(Tab.allCases) { tab in
                    Button {
                        appState.selectedTab = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 22))
                                .overlay(alignment: .topTrailing) {
                                    tabBadge(for: tab)
                                }
                            Text(tab.label)
                                .font(.caption2)
                        }
                        .foregroundStyle(appState.selectedTab == tab ? Theme.accent : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Theme.surface)
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
    }

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
            .onExitCommand {
                enableNavBar()
            }
            .onMoveCommand { direction in
                // For non-Guide screens, up enables nav bar
                if direction == .up && appState.selectedTab != .guide {
                    enableNavBar()
                }
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
            ForEach(Tab.allCases) { tab in
                Button {
                    // Click confirms selection and returns to content
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
                    List(Tab.allCases, selection: $appState.selectedTab) { tab in
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
                    switch appState.selectedTab {
                    case .guide:
                        GuideView()
                    case .topics:
                        TopicsView()
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
            }
        }
    }
}
#endif

#Preview {
    NavigationRouter()
        .environmentObject(AppState())
        .environmentObject(PVRClient())
}
