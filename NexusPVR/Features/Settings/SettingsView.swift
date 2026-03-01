//
//  SettingsView.swift
//  nextpvr-apple-client
//
//  Settings main view
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    #if os(tvOS)
    @Environment(\.requestNavBarFocus) private var requestNavBarFocus
    #endif
    @State private var showingUnlinkConfirm = false
    @State private var seekBackwardSeconds: Int = UserPreferences.load().seekBackwardSeconds
    @State private var seekForwardSeconds: Int = UserPreferences.load().seekForwardSeconds
    @State private var audioChannels: String = UserPreferences.load().audioChannels
    @State private var tvosGPUAPI: TVOSGPUAPI = UserPreferences.load().tvosGPUAPI
    @ObservedObject private var eventLog = NetworkEventLog.shared


    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSContent
                .alert("Unlink Server", isPresented: $showingUnlinkConfirm) {
                    Button("Unlink", role: .destructive) {
                        unlinkServer()
                    }
                    .accessibilityIdentifier("confirm-unlink-button")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will disconnect and forget the server. You'll need to set it up again.")
                }
            #else
            List {
                serverSection
                playbackSection
                eventLogLinkSection
            }
            .navigationTitle("Settings")
            #if os(macOS)
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            #elseif os(iOS)
            .listStyle(.insetGrouped)
            #endif
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
                    title: "\(Brand.serverName) Server",
                    icon: "server.rack",
                    statusView: {
                        if client.isAuthenticated {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.success)
                                Text("Connected")
                                    .foregroundStyle(Theme.success)
                            }
                        }
                    }
                ) {
                    VStack(spacing: Theme.spacingMD) {
                        HStack {
                            Text("Host")
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 80, alignment: .trailing)
                            Spacer()
                            Text(verbatim: "\(client.config.host):\(client.config.port)")
                                .foregroundStyle(Theme.textPrimary)
                        }

                        Button {
                            showingUnlinkConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                Text("Unlink Server")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.error)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        }
                        .buttonStyle(.card)
                        .accessibilityIdentifier("unlink-server-button")
                    }
                }
                .focusSection()
                .onMoveCommand { direction in
                    if direction == .up {
                        requestNavBarFocus()
                    }
                }

                // Playback Section
                TVSettingsSection(
                    title: "Playback",
                    icon: "play.circle"
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

                        Divider()
                            .background(Theme.textTertiary)

                        // Audio Output
                        VStack(spacing: Theme.spacingSM) {
                            Text("Audio Output")
                                .foregroundStyle(Theme.textPrimary)

                            HStack(spacing: Theme.spacingMD) {
                                ForEach(["auto", "stereo"], id: \.self) { mode in
                                    Button {
                                        audioChannels = mode
                                        var prefs = UserPreferences.load()
                                        prefs.audioChannels = mode
                                        prefs.save()
                                    } label: {
                                        Text(mode == "auto" ? "Auto" : "Stereo")
                                            .font(.callout)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, Theme.spacingLG)
                                            .padding(.vertical, Theme.spacingMD)
                                            .background(audioChannels == mode ? Theme.accent : Theme.surfaceElevated)
                                            .foregroundStyle(audioChannels == mode ? .white : Theme.textPrimary)
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                        }
                    }
                }
                .focusSection()

                #if DEBUG
                // Debug: Test Stream
                TVSettingsSection(
                    title: "Debug",
                    icon: "ladybug"
                ) {
                    VStack(spacing: Theme.spacingMD) {
                        VStack(spacing: Theme.spacingSM) {
                            Text("GPU API")
                                .foregroundStyle(Theme.textPrimary)

                            HStack(spacing: Theme.spacingMD) {
                                ForEach(TVOSGPUAPI.allCases, id: \.self) { api in
                                    Button {
                                        tvosGPUAPI = api
                                        var prefs = UserPreferences.load()
                                        prefs.tvosGPUAPI = api
                                        prefs.save()
                                    } label: {
                                        Text(api == .metal ? "Metal" : "OpenGL")
                                            .font(.callout)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, Theme.spacingLG)
                                            .padding(.vertical, Theme.spacingMD)
                                            .background(tvosGPUAPI == api ? Theme.accent : Theme.surfaceElevated)
                                            .foregroundStyle(tvosGPUAPI == api ? .white : Theme.textPrimary)
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                                    }
                                    .buttonStyle(.card)
                                }
                            }

                            Text("Applied on next playback start.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                        }

                        Divider()
                            .background(Theme.textTertiary)

                        Button {
                            let url = URL(filePath: "")
                            appState.playStream(url: url, title: "Test MKV Stream")
                        } label: {
                            HStack {
                                Image(systemName: "play.circle")
                                    .foregroundStyle(Theme.accent)
                                Text("Test MKV Stream")
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                            }
                            .padding()
                            .background(Theme.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        }
                        .buttonStyle(.card)
                    }
                }
                .focusSection()
                #endif

                // Event Log
                NavigationLink(destination: EventLogView()) {
                    HStack {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundStyle(Theme.accent)
                        Text("Event Log")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(eventLog.events.count)")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding()
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                }
                .buttonStyle(.card)
                .focusSection()

            }
            .padding(.vertical)
            .padding(.horizontal, 40)
        }
    }

    #endif

    private var serverSection: some View {
        Section {
            HStack {
                Text("Host")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(verbatim: "\(client.config.host):\(client.config.port)")
                    .foregroundStyle(Theme.textPrimary)
            }

            HStack {
                Text("Status")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if client.isAuthenticated {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text("Connected")
                            .foregroundStyle(Theme.success)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Theme.warning)
                        Text("Not Connected")
                            .foregroundStyle(Theme.warning)
                    }
                }
            }

            Button(role: .destructive) {
                showingUnlinkConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Label("Unlink Server", systemImage: "server.rack")
                    Spacer()
                }
            }
            .accessibilityIdentifier("unlink-server-button")
            .confirmationDialog("Unlink Server", isPresented: $showingUnlinkConfirm, titleVisibility: .visible) {
                Button("Unlink", role: .destructive) {
                    unlinkServer()
                }
                .accessibilityIdentifier("confirm-unlink-button")
            } message: {
                Text("This will disconnect and forget the server. You'll need to set it up again.")
            }
        } header: {
            Text("\(Brand.serverName) Server")
        }
    }

    private func unlinkServer() {
        client.disconnect()
        ServerConfig.clear()
        client.updateConfig(.default)
        #if DISPATCHERPVR
        client.useOutputEndpoints = false
        #endif
        appState.guideChannelFilter = ""
        appState.guideGroupFilter = nil
        appState.searchQuery = ""
        #if DISPATCHERPVR
        appState.userLevel = 10
        #endif
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

            Picker("Audio Output", selection: $audioChannels) {
                Text("Auto").tag("auto")
                Text("Stereo").tag("stereo")
            }
        } header: {
            Text("Playback")
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
        .onChange(of: audioChannels) {
            var prefs = UserPreferences.load()
            prefs.audioChannels = audioChannels
            prefs.save()
        }
    }

    private var eventLogLinkSection: some View {
        Section {
            NavigationLink(destination: EventLogView()) {
                HStack {
                    Label("Event Log", systemImage: "list.bullet.rectangle")
                    Spacer()
                    if !eventLog.events.isEmpty {
                        Text("\(eventLog.events.count)")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

}

#Preview {
    SettingsView()
        .environmentObject(PVRClient())
        .preferredColorScheme(.dark)
}
