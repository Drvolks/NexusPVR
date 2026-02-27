//
//  ContentView.swift
//  nextpvr-apple-client
//
//  Main content view with server configuration check
//

import SwiftUI

private struct SetupSheetConfig: Identifiable, Hashable {
    let id = UUID()
    let prefill: ServerConfig?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SetupSheetConfig, rhs: SetupSheetConfig) -> Bool {
        lhs.id == rhs.id
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var epgCache: EPGCache
    @StateObject private var discovery = ServerDiscoveryService()
    @State private var sheetConfig: SetupSheetConfig?
    @State private var isCheckingCloud = true
    #if os(tvOS)
    @FocusState private var focusedServerId: String?
    #endif
    #if DISPATCHERPVR
    @State private var discoveryUsername = ""
    @State private var discoveryPassword = ""
    @State private var discoveryApiKey = ""
    @State private var useApiKey = false
    @State private var hasStartedDiscovery = false
    @FocusState private var findServersFocused: Bool
    #endif

    var body: some View {
        Group {
            if isCheckingCloud {
                ProgressView()
            } else if client.isConfigured {
                NavigationRouter()
            } else {
                #if os(tvOS)
                NavigationStack {
                    setupPromptView
                        .navigationDestination(item: $sheetConfig) { config in
                            ServerConfigView(prefillConfig: config.prefill)
                                .environmentObject(client)
                        }
                }
                #else
                setupPromptView
                #endif
            }
        }
        #if !os(tvOS)
        .sheet(item: $sheetConfig) { config in
            ServerConfigView(prefillConfig: config.prefill)
                .environmentObject(client)
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 450)
                #endif
        }
        #endif
        .task {
            // Give iCloud a moment to sync, then check for config
            try? await Task.sleep(for: .milliseconds(500))

            // Reload config from iCloud if available
            let cloudConfig = ServerConfig.load()
            if cloudConfig.isConfigured && !client.isConfigured {
                client.updateConfig(cloudConfig)
            }

            // Authenticate before showing main UI to avoid race with GuideView
            // Retry briefly — macOS network may not be ready on cold launch
            // Cap total wait to 5s so unreachable servers don't block startup
            if client.isConfigured && !client.isAuthenticated {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for attempt in 1...3 {
                            do {
                                try await client.authenticate()
                                return
                            } catch {
                                if attempt < 3 {
                                    try? await Task.sleep(for: .seconds(1))
                                }
                            }
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(5))
                    }
                    // Whichever finishes first (auth success or timeout) unblocks
                    await group.next()
                    group.cancelAll()
                }
            }

            #if DISPATCHERPVR
            if client.isAuthenticated, let level = try? await client.fetchUserLevel() {
                appState.userLevel = level
                client.useOutputEndpoints = level < 1
            }
            #endif

            isCheckingCloud = false

            // Load EPG cache once authenticated
            if client.isConfigured {
                await epgCache.loadData(using: client)
            }

            // Only scan if no config found (NextPVR auto-scans; Dispatcharr waits for credentials)
            #if !DISPATCHERPVR
            if !client.isConfigured {
                discovery.startScan()
            }
            #endif
        }
        #if os(tvOS)
        .onChange(of: discovery.discoveredServers) { _, servers in
            if let first = servers.first, focusedServerId == nil {
                focusedServerId = first.id
            }
        }
        #endif
        .onChange(of: client.isConfigured) { _, isConfigured in
            if isConfigured {
                discovery.stopScan()
                // Authenticate, fetch user level, then load EPG — all sequentially
                Task {
                    if !client.isAuthenticated {
                        try? await client.authenticate()
                    }
                    #if DISPATCHERPVR
                    if client.isAuthenticated, let level = try? await client.fetchUserLevel() {
                        appState.userLevel = level
                        client.useOutputEndpoints = level < 1
                    }
                    #endif
                    await epgCache.loadData(using: client)
                }
            } else {
                // Server was unlinked — reset and restart discovery
                epgCache.invalidate()
                sheetConfig = nil
                #if DISPATCHERPVR
                hasStartedDiscovery = false
                discoveryUsername = ""
                discoveryPassword = ""
                discoveryApiKey = ""
                useApiKey = false
                #else
                discovery.startScan()
                #endif
            }
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
            }

            #if DISPATCHERPVR
            if hasStartedDiscovery {
                // Discovered servers section (after credentials entered)
                discoveredServersSection
            } else {
                // Credentials form before scanning
                credentialsForm
            }
            #else
            // Discovered servers section
            discoveredServersSection
            #endif

            Spacer()

            #if DISPATCHERPVR
            if hasStartedDiscovery {
                manualConfigButton
            }
            #else
            manualConfigButton
            #endif
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var manualConfigButton: some View {
        VStack(spacing: Theme.spacingMD) {
            Button {
                #if DISPATCHERPVR
                sheetConfig = SetupSheetConfig(prefill: ServerConfig(
                    host: "",
                    port: Brand.defaultPort,
                    pin: "",
                    username: discoveryUsername,
                    password: discoveryPassword,
                    apiKey: discoveryApiKey,
                    useHTTPS: false
                ))
                #else
                sheetConfig = SetupSheetConfig(prefill: nil)
                #endif
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Configure Server Manually")
                }
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding()
    }

    #if DISPATCHERPVR
    private var credentialsForm: some View {
        VStack(spacing: Theme.spacingMD) {
            Text("Enter your credentials to find servers on your network.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: Theme.spacingSM) {
                if useApiKey {
                    SecureField("API Key", text: $discoveryApiKey)
                        .textContentType(.password)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                        #if !os(tvOS)
                        .padding(Theme.spacingMD)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        #endif
                        .onSubmit {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                findServersFocused = true
                            }
                        }
                } else {
                    TextField("Username", text: $discoveryUsername)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                        .textContentType(.username)
                        #if !os(tvOS)
                        .padding(Theme.spacingMD)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        #endif

                    SecureField("Password", text: $discoveryPassword)
                        .textContentType(.password)
                        #if !os(tvOS)
                        .padding(Theme.spacingMD)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        #endif
                        .onSubmit {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                findServersFocused = true
                            }
                        }
                }
            }
            .frame(maxWidth: 400)

            Button {
                hasStartedDiscovery = true
                discovery.startScan(username: discoveryUsername, password: discoveryPassword, apiKey: useApiKey ? discoveryApiKey : "")
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Find Servers")
                }
            }
            .focused($findServersFocused)
            .buttonStyle(AccentButtonStyle())
            .disabled(useApiKey ? discoveryApiKey.isEmpty : (discoveryUsername.isEmpty || discoveryPassword.isEmpty))

            Button {
                useApiKey.toggle()
            } label: {
                Text(useApiKey ? "Use Username & Password" : "Use API Key")
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding(.horizontal, Theme.spacingLG)
    }
    #endif

    @ViewBuilder
    private var discoveredServersSection: some View {
        VStack(spacing: Theme.spacingSM) {
            if discovery.isScanning && discovery.discoveredServers.isEmpty {
                HStack(spacing: Theme.spacingSM) {
                    ProgressView()
                        .tint(Theme.accent)
                        #if os(tvOS)
                        .scaleEffect(0.8)
                        #endif
                    Text("Scanning local network...")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, Theme.spacingMD)
            }

            if !discovery.discoveredServers.isEmpty {
                VStack(spacing: Theme.spacingSM) {
                    HStack {
                        Text("Servers Found")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        if discovery.isScanning {
                            ProgressView()
                                .tint(Theme.accent)
                                .scaleEffect(0.6)
                        }
                    }

                    ForEach(discovery.discoveredServers) { server in
                        #if os(tvOS)
                        Button {
                            selectServer(server)
                        } label: {
                            serverRowContent(server)
                        }
                        .buttonStyle(.card)
                        .focused($focusedServerId, equals: server.id)
                        #else
                        Button {
                            selectServer(server)
                        } label: {
                            serverRowContent(server)
                        }
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .frame(maxWidth: 400)
            }
        }
    }

    private func serverRowContent(_ server: DiscoveredServer) -> some View {
        HStack(spacing: Theme.spacingMD) {
            Image(systemName: "server.rack")
                .foregroundStyle(Theme.accent)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(server.serverName)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if server.requiresAuth {
                    Text("Requires PIN")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                } else {
                    Text(verbatim: "\(server.host):\(server.port)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.spacingLG)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
    }

    private func selectServer(_ server: DiscoveredServer) {
        if server.requiresAuth {
            // Server needs credentials — open config with host/port pre-filled
            sheetConfig = SetupSheetConfig(prefill: ServerConfig(
                host: server.host,
                port: server.port,
                pin: "",
                useHTTPS: false
            ))
        } else {
            // Credentials verified during discovery — auto-connect
            #if DISPATCHERPVR
            let config = ServerConfig(
                host: server.host,
                port: server.port,
                pin: "",
                username: discoveryUsername,
                password: discoveryPassword,
                apiKey: discoveryApiKey,
                useHTTPS: false
            )
            #else
            let config = ServerConfig(
                host: server.host,
                port: server.port,
                pin: Brand.defaultPIN,
                useHTTPS: false
            )
            #endif
            config.save()
            client.updateConfig(config)
        }
    }
}

#Preview("Configured") {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(PVRClient(config: ServerConfig(host: "192.168.1.100", port: 8866, pin: "1234", useHTTPS: false)))
        .environmentObject(EPGCache())
        .preferredColorScheme(.dark)
}

#Preview("Not Configured") {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(PVRClient())
        .environmentObject(EPGCache())
        .preferredColorScheme(.dark)
}
