//
//  SettingsView.swift
//  nextpvr-apple-client
//
//  Settings main view
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var client: NextPVRClient
    @State private var showingServerConfig = false
    @State private var showingKeywordsEditor = false
    @State private var seekBackwardSeconds: Int = UserPreferences.load().seekBackwardSeconds
    @State private var seekForwardSeconds: Int = UserPreferences.load().seekForwardSeconds

    #if os(tvOS)
    @State private var serverConfig = ServerConfig.load()
    @State private var savedConfig = ServerConfig.load()
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var preferences = UserPreferences.load()
    @State private var newKeyword = ""
    @State private var showingAddKeyword = false

    private var hasConfigChanges: Bool {
        serverConfig != savedConfig
    }
    #endif

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSContent
                .alert("Connection Error", isPresented: .constant(connectionError != nil)) {
                    Button("OK") { connectionError = nil }
                } message: {
                    if let error = connectionError {
                        Text(error)
                    }
                }
            #else
            List {
                serverSection
                keywordsSection
                playbackSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .sheet(isPresented: $showingServerConfig) {
                ServerConfigView()
                    .environmentObject(client)
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 450)
                    #endif
            }
            .sheet(isPresented: $showingKeywordsEditor) {
                KeywordsEditorView()
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 400)
                    #endif
            }
            #endif
        }
        .background(Theme.background)
    }

    #if os(tvOS)
    private var tvOSContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingXL) {
                // Server Section
                TVSettingsSection(
                    title: "NextPVR Server",
                    icon: "server.rack",
                    statusView: {
                        if client.isAuthenticated && !hasConfigChanges {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.success)
                                Text("Connected")
                                    .foregroundStyle(Theme.success)
                            }
                        } else if isConnecting {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(Theme.accent)
                                Text("Connecting...")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                ) {
                    VStack(spacing: Theme.spacingMD) {
                        HStack {
                            Text("Host")
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 80, alignment: .trailing)
                            TVTextField(placeholder: "192.168.1.100", text: $serverConfig.host)
                        }

                        HStack {
                            Text("Port")
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 80, alignment: .trailing)
                            TVNumberField(placeholder: "8866", value: $serverConfig.port)
                        }

                        HStack {
                            Text("PIN")
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 80, alignment: .trailing)
                            TVTextField(placeholder: "0000", text: $serverConfig.pin)
                        }

                        Button {
                            saveAndConnect()
                        } label: {
                            HStack {
                                if isConnecting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "link")
                                }
                                Text(isConnecting ? "Connecting..." : "Connect")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(hasConfigChanges && serverConfig.isConfigured ? Theme.accent : Theme.surfaceElevated)
                            .foregroundStyle(hasConfigChanges && serverConfig.isConfigured ? .white : Theme.textTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        }
                        .buttonStyle(.card)
                        .disabled(!hasConfigChanges || !serverConfig.isConfigured || isConnecting)
                    }
                }
                .focusSection()

                // Topics Section
                TVSettingsSection(
                    title: "Topic Keywords",
                    icon: "star.fill",
                    footer: "Keywords are matched against program titles and descriptions"
                ) {
                    VStack(spacing: Theme.spacingMD) {
                        if !preferences.keywords.isEmpty {
                            ForEach(preferences.keywords, id: \.self) { keyword in
                                HStack {
                                    Text(keyword)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Button {
                                        removeKeyword(keyword)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(Theme.error)
                                            .font(.title3)
                                    }
                                    .buttonStyle(.card)
                                }
                                .padding(.vertical, Theme.spacingXS)
                            }

                            Divider()
                                .background(Theme.textTertiary)
                        }

                        Button {
                            showingAddKeyword = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.accent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        }
                        .buttonStyle(.card)
                    }
                }
                .focusSection()
                .alert("Add Keyword", isPresented: $showingAddKeyword) {
                    TextField("Keyword", text: $newKeyword)
                    Button("Add") { addKeyword() }
                    Button("Cancel", role: .cancel) { newKeyword = "" }
                }

                // Playback Section
                TVSettingsSection(
                    title: "Playback",
                    icon: "play.circle",
                    footer: "Time to skip when using seek controls"
                ) {
                    VStack(spacing: Theme.spacingMD) {
                        // Seek Backward
                        VStack(spacing: Theme.spacingSM) {
                            Text("Seek Backward")
                                .foregroundStyle(Theme.textPrimary)

                            HStack(spacing: Theme.spacingMD) {
                                ForEach([5, 10, 15, 30], id: \.self) { seconds in
                                    Button {
                                        seekBackwardSeconds = seconds
                                        var prefs = UserPreferences.load()
                                        prefs.seekBackwardSeconds = seconds
                                        prefs.save()
                                    } label: {
                                        Text("\(seconds)s")
                                            .font(.callout)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, Theme.spacingLG)
                                            .padding(.vertical, Theme.spacingMD)
                                            .background(seekBackwardSeconds == seconds ? Theme.accent : Theme.surfaceElevated)
                                            .foregroundStyle(seekBackwardSeconds == seconds ? .white : Theme.textPrimary)
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                        }

                        Divider()
                            .background(Theme.textTertiary)

                        // Seek Forward
                        VStack(spacing: Theme.spacingSM) {
                            Text("Seek Forward")
                                .foregroundStyle(Theme.textPrimary)

                            HStack(spacing: Theme.spacingMD) {
                                ForEach([15, 30, 45, 60], id: \.self) { seconds in
                                    Button {
                                        seekForwardSeconds = seconds
                                        var prefs = UserPreferences.load()
                                        prefs.seekForwardSeconds = seconds
                                        prefs.save()
                                    } label: {
                                        Text("\(seconds)s")
                                            .font(.callout)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, Theme.spacingLG)
                                            .padding(.vertical, Theme.spacingMD)
                                            .background(seekForwardSeconds == seconds ? Theme.accent : Theme.surfaceElevated)
                                            .foregroundStyle(seekForwardSeconds == seconds ? .white : Theme.textPrimary)
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                        }
                    }
                }
                .focusSection()
            }
            .padding(.vertical)
            .padding(.horizontal, 40)
        }
    }


    private func saveAndConnect() {
        guard serverConfig.isConfigured else { return }

        isConnecting = true
        connectionError = nil

        serverConfig.save()
        client.updateConfig(serverConfig)

        Task {
            do {
                try await client.authenticate()
                isConnecting = false
                savedConfig = serverConfig
            } catch {
                isConnecting = false
                connectionError = error.localizedDescription
            }
        }
    }

    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !preferences.keywords.contains(trimmed) else {
            newKeyword = ""
            return
        }

        preferences.keywords.append(trimmed)
        preferences.save()
        newKeyword = ""
    }

    private func removeKeyword(_ keyword: String) {
        preferences.keywords.removeAll { $0 == keyword }
        preferences.save()
    }
    #endif

    private var keywordsSection: some View {
        Section {
            Button {
                showingKeywordsEditor = true
            } label: {
                HStack {
                    Label("Topic Keywords", systemImage: "star.fill")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    let prefs = UserPreferences.load()
                    if !prefs.keywords.isEmpty {
                        Text("\(prefs.keywords.count)")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .foregroundStyle(Theme.textPrimary)
            #endif
        } header: {
            Text("Topics")
        } footer: {
            Text("Add keywords to find matching programs in the Topics tab")
        }
    }

    private var serverSection: some View {
        Section {
            Button {
                showingServerConfig = true
            } label: {
                HStack {
                    Label("Server Configuration", systemImage: "server.rack")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if client.isAuthenticated {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                    } else if client.isConfigured {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .foregroundStyle(Theme.textPrimary)
            #endif

            if client.isAuthenticated {
                HStack {
                    Text("Status")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("Connected")
                        .foregroundStyle(Theme.success)
                }
            } else if client.isConfigured {
                HStack {
                    Text("Status")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("Not Connected")
                        .foregroundStyle(Theme.warning)
                }
            }
        } header: {
            Text("NextPVR Server")
        }
    }

    private var playbackSection: some View {
        Section {
            Picker("Seek Backward", selection: $seekBackwardSeconds) {
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
                Text("15 seconds").tag(15)
                Text("30 seconds").tag(30)
            }

            Picker("Seek Forward", selection: $seekForwardSeconds) {
                Text("15 seconds").tag(15)
                Text("30 seconds").tag(30)
                Text("45 seconds").tag(45)
                Text("60 seconds").tag(60)
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Time to skip when using seek controls")
        }
        .onChange(of: seekBackwardSeconds) {
            var prefs = UserPreferences.load()
            prefs.seekBackwardSeconds = seekBackwardSeconds
            prefs.save()
        }
        .onChange(of: seekForwardSeconds) {
            var prefs = UserPreferences.load()
            prefs.seekForwardSeconds = seekForwardSeconds
            prefs.save()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(NextPVRClient())
        .preferredColorScheme(.dark)
}
