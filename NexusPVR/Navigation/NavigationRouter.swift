//
//  NavigationRouter.swift
//  nextpvr-apple-client
//
//  Platform-adaptive navigation
//

import SwiftUI

struct NavigationRouter: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: NextPVRClient

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
    }
}

// MARK: - iOS/iPadOS Navigation

#if os(iOS)
struct IOSNavigation: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: NextPVRClient

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
}
#endif

// MARK: - tvOS Navigation

#if os(tvOS)
struct TVOSNavigation: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: NextPVRClient

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            GuideView()
                .tabItem {
                    Label(Tab.guide.label, systemImage: Tab.guide.icon)
                }
                .tag(Tab.guide)

            RecordingsListView()
                .tabItem {
                    Label(Tab.recordings.label, systemImage: Tab.recordings.icon)
                }
                .tag(Tab.recordings)

            TopicsView()
                .tabItem {
                    Label(Tab.topics.label, systemImage: Tab.topics.icon)
                }
                .tag(Tab.topics)

            SettingsView()
                .tabItem {
                    Label(Tab.settings.label, systemImage: Tab.settings.icon)
                }
                .tag(Tab.settings)
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
}
#endif

// MARK: - macOS Navigation

#if os(macOS)
struct MacOSNavigation: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: NextPVRClient

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
                        Label(tab.label, systemImage: tab.icon)
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
        .environmentObject(NextPVRClient())
}
