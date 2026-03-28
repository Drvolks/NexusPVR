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
    @Environment(\.requestSidebarFocus) private var requestSidebarFocus
    #endif
    @State private var showingUnlinkConfirm = false
    @State private var seekBackwardSeconds: Int = UserPreferences.load().seekBackwardSeconds
    @State private var seekForwardSeconds: Int = UserPreferences.load().seekForwardSeconds
    @State private var audioChannels: String = UserPreferences.load().audioChannels
    @State private var tvosGPUAPI: GPUAPI = UserPreferences.load().tvosGPUAPI
    @State private var iosGPUAPI: GPUAPI = UserPreferences.load().iosGPUAPI
    @State private var macosGPUAPI: GPUAPI = UserPreferences.load().macosGPUAPI
    @ObservedObject private var eventLog = NetworkEventLog.shared
    #if os(tvOS)
    @State private var activeTVPopup: TVSettingsPopup?
    @FocusState private var popupFocusedItemID: String?
    @State private var showingTVEventLog = false
    #endif
    #if DEBUG
    @State private var debugStreamEnabled: Bool = UserDefaults.standard.bool(forKey: "debugStreamEnabled")
    @State private var debugStreamURL: String = UserDefaults.standard.string(forKey: "debugStreamURL") ?? "http://localhost:9000/video"
    #endif

    #if os(tvOS)
    private enum TVSettingsPopup: Hashable {
        case server
        case seekBackward
        case seekForward
        case audioOutput
        case renderer
    }
    #endif

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSContent
            #else
            List {
                serverSection
                playbackSection
                #if DEBUG
                debugStreamSection
                #endif
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
            .sidebarMenuToolbar()
            #endif
            #endif
        }
        .accessibilityIdentifier("settings-view")
        #if os(tvOS)
        .background(.ultraThinMaterial)
        #else
        .background(Theme.background)
        #endif
    }

    #if os(tvOS)
    private var tvOSContent: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingXL) {
                    HStack(alignment: .center, spacing: Theme.spacingMD) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Theme.guideNowPlaying.opacity(0.95))
                                .frame(width: 56, height: 56)
                            Image(systemName: "gearshape.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Settings")
                                .font(.system(size: 38, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Playback, server and diagnostics")
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Theme.spacingSM)
                    .padding(.vertical, Theme.spacingSM)

                    TVSettingsSection(
                        title: "\(Brand.serverName) Server",
                        icon: "server.rack"
                    ) {
                        tvSettingsRow(
                            title: "Server",
                            value: serverSummaryValue,
                            icon: "network"
                        ) {
                            activeTVPopup = .server
                        }
                    }
                    .focusSection()

                    TVSettingsSection(
                        title: "Playback",
                        icon: "play.circle"
                    ) {
                        VStack(spacing: Theme.spacingMD) {
                            tvSettingsRow(
                                title: "Seek Backward",
                                value: "\(seekBackwardSeconds)s",
                                icon: "gobackward"
                            ) {
                                activeTVPopup = .seekBackward
                            }
                            tvSettingsRow(
                                title: "Seek Forward",
                                value: "\(seekForwardSeconds)s",
                                icon: "goforward"
                            ) {
                                activeTVPopup = .seekForward
                            }
                            tvSettingsRow(
                                title: "Audio Output",
                                value: audioChannels == "stereo" ? "Stereo" : "Auto",
                                icon: "speaker.wave.2"
                            ) {
                                activeTVPopup = .audioOutput
                            }
                            tvSettingsRow(
                                title: "Renderer",
                                value: rendererName(for: tvosGPUAPI),
                                icon: "display.2",
                                detail: rendererDescription(for: tvosGPUAPI)
                            ) {
                                activeTVPopup = .renderer
                            }
                        }
                    }
                    .focusSection()

                #if DEBUG
                    TVSettingsSection(
                        title: "Debug",
                        icon: "ladybug"
                    ) {
                        VStack(spacing: Theme.spacingMD) {
                            Toggle("Test Stream", isOn: $debugStreamEnabled)
                                .onChange(of: debugStreamEnabled) { _, newValue in
                                    UserDefaults.standard.set(newValue, forKey: "debugStreamEnabled")
                                }

                            if debugStreamEnabled {
                                HStack(spacing: 8) {
                                    TextField("Stream URL", text: $debugStreamURL)
                                        .autocorrectionDisabled()
                                        .onChange(of: debugStreamURL) { _, newValue in
                                            UserDefaults.standard.set(newValue, forKey: "debugStreamURL")
                                        }
                                }

                                Button {
                                    if let url = URL(string: debugStreamURL) {
                                        appState.playStream(url: url, title: "Test Stream")
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "play.circle")
                                            .foregroundStyle(Theme.accent)
                                        Text("Play Test Stream")
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
                    }
                    .focusSection()
                #endif

                    tvSettingsActionRow(
                        title: "Event Log",
                        value: "\(eventLog.events.count)",
                        icon: "list.bullet.rectangle",
                        action: {
                            showingTVEventLog = true
                        }
                    )
                    .focusSection()

                }
                .padding(.vertical, Theme.spacingXL)
                .padding(.horizontal, 36)
                .background {
                    NavigationLink(isActive: $showingTVEventLog) {
                        EventLogView()
                    } label: {
                        EmptyView()
                    }
                    .hidden()
                }
            }
            .allowsHitTesting(activeTVPopup == nil)
            .opacity(activeTVPopup == nil ? 1 : 0.6)

            if let activeTVPopup {
                tvSettingsPopup(for: activeTVPopup)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: activeTVPopup)
        .onAppear {
            appState.tvosBlocksSidebarExitCommand = activeTVPopup != nil || showingTVEventLog
            appState.tvosSettingsHasPopup = activeTVPopup != nil
            appState.tvosSettingsShowingEventLog = showingTVEventLog
        }
        .onChange(of: activeTVPopup) { _, _ in
            appState.tvosBlocksSidebarExitCommand = activeTVPopup != nil || showingTVEventLog
            appState.tvosSettingsHasPopup = activeTVPopup != nil
        }
        .onChange(of: showingTVEventLog) { _, _ in
            appState.tvosBlocksSidebarExitCommand = activeTVPopup != nil || showingTVEventLog
            appState.tvosSettingsShowingEventLog = showingTVEventLog
        }
        .onChange(of: appState.tvosSettingsDismissPopupRequest) { _, _ in
            activeTVPopup = nil
        }
        .onChange(of: appState.tvosSettingsDismissEventLogRequest) { _, _ in
            showingTVEventLog = false
        }
        .onExitCommand {
            if activeTVPopup != nil {
                activeTVPopup = nil
            } else if showingTVEventLog {
                showingTVEventLog = false
            } else {
                requestSidebarFocus()
            }
        }
    }

    private func tvSettingsRow(
        title: String,
        value: String,
        icon: String,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.spacingMD) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(value)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.vertical, Theme.spacingMD)
            .background(Theme.guideNowPlaying.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        }
        .buttonStyle(TVSettingsRowButtonStyle())
    }

    private func tvSettingsActionRow(
        title: String,
        value: String,
        icon: String,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.spacingMD) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(value)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.vertical, Theme.spacingMD)
            .background(Theme.guideNowPlaying.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        }
        .buttonStyle(TVSettingsRowButtonStyle())
    }

    private var serverSummaryValue: String {
        let host = client.config.displayAddress.isEmpty ? "Not configured" : client.config.displayAddress
        let status = client.isAuthenticated ? "Connected" : "Not Connected"
        return "\(host) \(status)"
    }

    private func rendererName(for api: GPUAPI) -> String {
        switch api {
        case .metal:
            return "Metal"
        case .pixelbuffer:
            return "PixelBuffer (Recommended)"
        case .opengl:
            return "OpenGL"
        }
    }

    @ViewBuilder
    private func tvSettingsPopup(for popup: TVSettingsPopup) -> some View {
        let options = popupOptions(for: popup)
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()
                .onTapGesture {
                    activeTVPopup = nil
                }

            VStack(alignment: .leading, spacing: Theme.spacingMD) {
                Text(popupTitle(for: popup))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                VStack(spacing: Theme.spacingSM) {
                    ForEach(options, id: \.id) { option in
                        Button(option.title) {
                            option.action()
                            activeTVPopup = nil
                        }
                        .buttonStyle(TVSettingsPopupButtonStyle(variant: option.isDestructive ? .destructive : .regular))
                        .focused($popupFocusedItemID, equals: option.id)
                    }

                    Button("Cancel") {
                        activeTVPopup = nil
                    }
                    .buttonStyle(TVSettingsPopupButtonStyle(variant: .cancel))
                    .focused($popupFocusedItemID, equals: "settings-popup-cancel")
                }
            }
            .padding(Theme.spacingLG)
            .frame(maxWidth: 920)
            .background(Theme.surface.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLG))
            .onAppear {
                let currentOptionID = options.first(where: { $0.isCurrent })?.id ?? "settings-popup-cancel"
                DispatchQueue.main.async {
                    popupFocusedItemID = currentOptionID
                }
            }
            .onExitCommand {
                activeTVPopup = nil
            }
        }
    }

    private func popupTitle(for popup: TVSettingsPopup) -> String {
        switch popup {
        case .server:
            return "Server"
        case .seekBackward:
            return "Seek Backward"
        case .seekForward:
            return "Seek Forward"
        case .audioOutput:
            return "Audio Output"
        case .renderer:
            return "Renderer"
        }
    }

    private struct TVPopupOption {
        let id: String
        let title: String
        let isCurrent: Bool
        let isDestructive: Bool
        let action: () -> Void
    }

    private func popupOptions(for popup: TVSettingsPopup) -> [TVPopupOption] {
        switch popup {
        case .server:
            return [
                TVPopupOption(id: "settings-popup-server-unlink", title: "Unlink Server", isCurrent: true, isDestructive: true) {
                    unlinkServer()
                }
            ]
        case .seekBackward:
            return [5, 10, 15, 30].map { seconds in
                TVPopupOption(
                    id: "settings-popup-seek-backward-\(seconds)",
                    title: "\(seconds)s",
                    isCurrent: seekBackwardSeconds == seconds,
                    isDestructive: false
                ) {
                    seekBackwardSeconds = seconds
                    var prefs = UserPreferences.load()
                    prefs.seekBackwardSeconds = seconds
                    prefs.save()
                }
            }
        case .seekForward:
            return [15, 30, 45, 60].map { seconds in
                TVPopupOption(
                    id: "settings-popup-seek-forward-\(seconds)",
                    title: "\(seconds)s",
                    isCurrent: seekForwardSeconds == seconds,
                    isDestructive: false
                ) {
                    seekForwardSeconds = seconds
                    var prefs = UserPreferences.load()
                    prefs.seekForwardSeconds = seconds
                    prefs.save()
                }
            }
        case .audioOutput:
            return [
                TVPopupOption(id: "settings-popup-audio-auto", title: "Auto", isCurrent: audioChannels == "auto", isDestructive: false) {
                    audioChannels = "auto"
                    var prefs = UserPreferences.load()
                    prefs.audioChannels = "auto"
                    prefs.save()
                },
                TVPopupOption(id: "settings-popup-audio-stereo", title: "Stereo", isCurrent: audioChannels == "stereo", isDestructive: false) {
                    audioChannels = "stereo"
                    var prefs = UserPreferences.load()
                    prefs.audioChannels = "stereo"
                    prefs.save()
                }
            ]
        case .renderer:
            return GPUAPI.allCases.map { api in
                TVPopupOption(
                    id: "settings-popup-renderer-\(rendererName(for: api))",
                    title: rendererName(for: api),
                    isCurrent: tvosGPUAPI == api,
                    isDestructive: false
                ) {
                    tvosGPUAPI = api
                    var prefs = UserPreferences.load()
                    prefs.tvosGPUAPI = api
                    prefs.save()
                }
            }
        }
    }

    #endif

    private var serverSection: some View {
        Section {
            HStack {
                Text("Host")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(verbatim: client.config.displayAddress)
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

            #if os(iOS)
            Picker("Renderer", selection: $iosGPUAPI) {
                Text("OpenGL").tag(GPUAPI.opengl)
                Text("Metal").tag(GPUAPI.metal)
                Text("PixelBuffer (Recommended)").tag(GPUAPI.pixelbuffer)
            }
            Text(rendererDescription(for: iosGPUAPI))
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            #elseif os(macOS)
            Picker("Renderer", selection: $macosGPUAPI) {
                Text("OpenGL").tag(GPUAPI.opengl)
                Text("Metal").tag(GPUAPI.metal)
                Text("PixelBuffer (Recommended)").tag(GPUAPI.pixelbuffer)
            }
            Text(rendererDescription(for: macosGPUAPI))
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            #endif
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
        #if os(iOS)
        .onChange(of: iosGPUAPI) {
            var prefs = UserPreferences.load()
            prefs.iosGPUAPI = iosGPUAPI
            prefs.save()
        }
        #elseif os(macOS)
        .onChange(of: macosGPUAPI) {
            var prefs = UserPreferences.load()
            prefs.macosGPUAPI = macosGPUAPI
            prefs.save()
        }
        #endif
    }

    private func rendererDescription(for api: GPUAPI) -> String {
        switch api {
        case .pixelbuffer:
            return "Renders directly to a Metal surface + Supports native Picture-in-Picture"
        case .metal:
            return "Renders directly to a Metal surface. May offer lower latency but lacks Picture-in-Picture support."
        case .opengl:
            return "Legacy OpenGL-based rendering. Broad compatibility but no Picture-in-Picture support."
        }
    }

    #if DEBUG
    private var debugStreamSection: some View {
        Section {
            Toggle("Test Stream Override", isOn: $debugStreamEnabled)
                .onChange(of: debugStreamEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "debugStreamEnabled")
                }

            if debugStreamEnabled {
                TextField("Stream URL", text: $debugStreamURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: debugStreamURL) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "debugStreamURL")
                    }

                Button("Play Test Stream") {
                    if let url = URL(string: debugStreamURL) {
                        appState.playStream(url: url, title: "Test Stream")
                    }
                }
            }
        } header: {
            Text("Debug")
        }
    }
    #endif

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

#if os(tvOS)
private struct TVSettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadiusSM)
                    .stroke(isFocused ? Theme.accent : Color.clear, lineWidth: isFocused ? 3 : 0)
            }
            .shadow(color: isFocused ? Theme.accent.opacity(0.24) : .clear, radius: 12)
            .scaleEffect(configuration.isPressed ? 0.985 : isFocused ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.14), value: isFocused)
    }
}

private struct TVSettingsPopupButtonStyle: ButtonStyle {
    enum Variant {
        case regular
        case destructive
        case cancel
    }

    let variant: Variant
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .padding(.vertical, Theme.spacingMD)
            .frame(maxWidth: .infinity)
            .background(backgroundColor(configuration: configuration))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadiusMD)
                    .stroke(isFocused ? Theme.accent : Color.clear, lineWidth: isFocused ? 3 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : isFocused ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.14), value: isFocused)
    }

    private var foregroundColor: Color {
        switch variant {
        case .destructive:
            return .white
        case .regular, .cancel:
            return Theme.textPrimary
        }
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        let base: Color
        switch variant {
        case .regular:
            base = Theme.guideNowPlaying.opacity(0.9)
        case .cancel:
            base = Theme.surfaceElevated.opacity(0.9)
        case .destructive:
            base = Theme.error.opacity(0.9)
        }
        return configuration.isPressed ? base.opacity(0.72) : base
    }
}
#endif

#Preview {
    SettingsView()
        .environmentObject(PVRClient())
        .preferredColorScheme(.dark)
}
