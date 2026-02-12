//
//  SettingsView.swift
//  nextpvr-apple-client
//
//  Settings main view
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var client: PVRClient
    @State private var showingUnlinkConfirm = false
    @State private var seekBackwardSeconds: Int = UserPreferences.load().seekBackwardSeconds
    @State private var seekForwardSeconds: Int = UserPreferences.load().seekForwardSeconds


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
                playbackSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
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
                    }
                }
                .focusSection()

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

}

#Preview {
    SettingsView()
        .environmentObject(PVRClient())
        .preferredColorScheme(.dark)
}
