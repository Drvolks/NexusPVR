//
//  ContentView.swift
//  nextpvr-apple-client
//
//  Main content view with server configuration check
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: PVRClient
    @State private var showingSetup = false
    @State private var isCheckingCloud = true

    var body: some View {
        Group {
            if isCheckingCloud {
                ProgressView()
            } else if client.isConfigured {
                NavigationRouter()
            } else {
                setupPromptView
            }
        }
        .sheet(isPresented: $showingSetup) {
            ServerConfigView()
                .environmentObject(client)
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 450)
                #endif
        }
        .task {
            // Give iCloud a moment to sync, then check for config
            try? await Task.sleep(for: .milliseconds(500))

            // Reload config from iCloud if available
            let cloudConfig = ServerConfig.load()
            if cloudConfig.isConfigured && !client.isConfigured {
                client.updateConfig(cloudConfig)
            }

            // Authenticate before showing main UI to avoid race with GuideView
            if client.isConfigured && !client.isAuthenticated {
                try? await client.authenticate()
            }

            isCheckingCloud = false
        }
    }

    private var setupPromptView: some View {
        VStack(spacing: Theme.spacingXL) {
            Spacer()

            // App icon/logo
            VStack(spacing: Theme.spacingMD) {
                Image(systemName: "tv.and.mediabox")
                    .font(.system(size: 80))
                    .foregroundStyle(Theme.accent)

                Text(Brand.appName)
                    .font(.displayLarge)
                    .foregroundStyle(Theme.textPrimary)

                Text(Brand.subtitle)
                    .font(.title2)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            // Setup prompt
            VStack(spacing: Theme.spacingMD) {
                Text("Welcome!")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                Text(Brand.setupPrompt)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingSetup = true
                } label: {
                    HStack {
                        Image(systemName: "gear")
                        Text("Configure Server")
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .padding(.top, Theme.spacingMD)
            }
            .padding()

            Spacer()

            // Footer
            Text("v1.0.0")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

#Preview("Configured") {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(PVRClient(config: ServerConfig(host: "192.168.1.100", port: 8866, pin: "1234", useHTTPS: false)))
        .preferredColorScheme(.dark)
}

#Preview("Not Configured") {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(PVRClient())
        .preferredColorScheme(.dark)
}
