//
//  SettingsView.swift
//  nextpvr-apple-client
//
//  Settings main view
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var client: PVRClient
    @State private var showingKeywordsEditor = false
    @State private var showingUnlinkConfirm = false
    @State private var seekBackwardSeconds: Int = UserPreferences.load().seekBackwardSeconds
    @State private var seekForwardSeconds: Int = UserPreferences.load().seekForwardSeconds

    #if os(tvOS)
    @State private var preferences = UserPreferences.load()
    @State private var newKeyword = ""
    @State private var showingAddKeyword = false
    #endif

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSContent
                .confirmationDialog("Unlink Server", isPresented: $showingUnlinkConfirm, titleVisibility: .visible) {
                    Button("Unlink", role: .destructive) {
                        unlinkServer()
                    }
                } message: {
                    Text("This will disconnect and forget the server. You'll need to set it up again.")
                }
            #else
            List {
                serverSection
                keywordsSection
                playbackSection
                playerStatsSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
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
                    }
                }
                .focusSection()

                // Player Stats Section
                playerStatsSection
            }
            .padding(.vertical)
            .padding(.horizontal, 40)
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
            .confirmationDialog("Unlink Server", isPresented: $showingUnlinkConfirm, titleVisibility: .visible) {
                Button("Unlink", role: .destructive) {
                    unlinkServer()
                }
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

    #if os(tvOS)
    private var playerStatsSection: some View {
        let stats = PlayerStats.load()
        return TVSettingsSection(
            title: "Player Stats",
            icon: "chart.bar",
            footer: "From last played video"
        ) {
            VStack(spacing: Theme.spacingSM) {
                statsRow(label: "Avg FPS", value: stats.avgFps > 0 ? String(format: "%.1f", stats.avgFps) : "--")
                statsRow(label: "Avg Bitrate", value: stats.avgBitrateKbps > 0 ? String(format: "%.0f kbps", stats.avgBitrateKbps) : "--")
                statsRow(label: "Max A/V Sync", value: stats.maxAvsync > 0 ? String(format: "%.3f s", stats.maxAvsync) : "--")
                statsRow(label: "Dropped Frames", value: "\(stats.totalDroppedFrames)")
                statsRow(label: "Decoder Dropped", value: "\(stats.totalDecoderDroppedFrames)")
                statsRow(label: "VO Delayed", value: "\(stats.totalVoDelayedFrames)")
            }
        }
    }
    #else
    private var playerStatsSection: some View {
        let stats = PlayerStats.load()
        return Section {
            statsRow(label: "Avg FPS", value: stats.avgFps > 0 ? String(format: "%.1f", stats.avgFps) : "--")
            statsRow(label: "Avg Bitrate", value: stats.avgBitrateKbps > 0 ? String(format: "%.0f kbps", stats.avgBitrateKbps) : "--")
            statsRow(label: "Max A/V Sync", value: stats.maxAvsync > 0 ? String(format: "%.3f s", stats.maxAvsync) : "--")
            statsRow(label: "Dropped Frames", value: "\(stats.totalDroppedFrames)")
            statsRow(label: "Decoder Dropped", value: "\(stats.totalDecoderDroppedFrames)")
            statsRow(label: "VO Delayed", value: "\(stats.totalVoDelayedFrames)")
        } header: {
            Text("Player Stats")
        } footer: {
            Text("From last played video")
        }
    }
    #endif

    private func statsRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(PVRClient())
        .preferredColorScheme(.dark)
}
