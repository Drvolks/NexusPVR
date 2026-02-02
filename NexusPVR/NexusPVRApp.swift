//
//  NexusPVRApp.swift
//  NexusPVR
//
//  NextPVR client for iOS, iPadOS, tvOS, and macOS
//

import SwiftUI

@main
struct NexusPVRApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var client = NextPVRClient()

    init() {
        // Trigger iCloud sync on startup to pull latest data
        NSUbiquitousKeyValueStore.default.synchronize()

        // Start observing iCloud preference sync
        UserPreferences.startObservingSync {
            // Post notification when preferences change from another device
            NotificationCenter.default.post(name: .preferencesDidSync, object: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(client)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .ignoresSafeArea()
                .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
                    // Reload server config if it changed from iCloud
                    let newConfig = ServerConfig.load()
                    if newConfig.isConfigured && newConfig != client.config {
                        client.updateConfig(newConfig)
                    }
                }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}
