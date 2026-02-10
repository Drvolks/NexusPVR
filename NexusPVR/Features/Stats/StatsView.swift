//
//  StatsView.swift
//  DispatcherPVR
//
//  Displays active proxy stream status from Dispatcharr
//

#if DISPATCHERPVR
import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: PVRClient
    @StateObject private var vm = StatsViewModel()

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        standardBody
        #endif
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
    private var standardBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingMD) {
                header
                    .padding(.horizontal)

                if vm.isLoading && vm.channels.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = vm.error, vm.channels.isEmpty {
                    errorView(error)
                } else if vm.channels.isEmpty {
                    emptyView
                } else {
                    LazyVStack(spacing: Theme.spacingMD) {
                        ForEach(vm.channels) { channel in
                            ChannelStatusCard(channel: channel)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Theme.background)
        .task {
            vm.startRefreshing(client: client as! DispatcherClient, appState: appState)
        }
        .onDisappear {
            vm.stopRefreshing()
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingLG) {
                header
                    .padding(.horizontal, 80)

                if vm.isLoading && vm.channels.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if let error = vm.error, vm.channels.isEmpty {
                    errorView(error)
                        .padding(.horizontal, 80)
                } else if vm.channels.isEmpty {
                    emptyView
                        .padding(.horizontal, 80)
                } else {
                    LazyVStack(spacing: Theme.spacingLG) {
                        ForEach(vm.channels) { channel in
                            ChannelStatusCard(channel: channel)
                        }
                    }
                    .padding(.horizontal, 80)
                }
            }
            .padding(.vertical, 40)
        }
        .background(Theme.background)
        .task {
            vm.startRefreshing(client: client as! DispatcherClient, appState: appState)
        }
        .onDisappear {
            vm.stopRefreshing()
        }
    }
    #endif

    // MARK: - Shared Components

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Active Streams")
                    .font(.displayMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(vm.activeCount) active channel\(vm.activeCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !vm.channels.isEmpty {
                Circle()
                    .fill(Theme.success)
                    .frame(width: 10, height: 10)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: Theme.spacingSM) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyView: some View {
        VStack(spacing: Theme.spacingSM) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No Active Streams")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Channels will appear here when they are being streamed")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

// MARK: - Channel Status Card

struct ChannelStatusCard: View {
    let channel: ProxyChannelStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            // Header: name + profile + state badge
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.streamName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if let profile = channel.m3uProfileName {
                        Text("(\(profile))")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                StateBadge(state: channel.state)
            }

            // Stats grid
            #if os(tvOS)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.spacingSM) {
                statsRows
            }
            #else
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.spacingSM) {
                statsRows
            }
            #endif

            // Connected clients
            if let clients = channel.clients, !clients.isEmpty {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    Text("Connected Clients (\(channel.clientCount ?? clients.count))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    ForEach(clients) { client in
                        ClientRow(client: client)
                    }
                }
            }
        }
        .padding()
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
    }

    @ViewBuilder
    private var statsRows: some View {
        if let resolution = channel.resolution {
            StatRow(label: "Resolution", value: resolution)
        }
        StatRow(label: "Codecs", value: codecString)
        if let bitrate = channel.avgBitrate {
            StatRow(label: "Bitrate", value: bitrate)
        }
        if let fps = channel.sourceFps {
            StatRow(label: "FPS", value: String(format: "%.0f", fps))
        }
        if let speed = channel.ffmpegSpeed {
            StatRow(label: "FFmpeg Speed", value: String(format: "%.2fx", speed))
        }
        if let uptime = channel.uptime {
            StatRow(label: "Uptime", value: formatUptime(uptime))
        }
        if let bytes = channel.totalBytes {
            StatRow(label: "Total Data", value: formatBytes(bytes))
        }
    }

    private var codecString: String {
        var parts: [String] = []
        if let vc = channel.videoCodec { parts.append(vc.uppercased()) }
        if let ac = channel.audioCodec {
            var s = ac.uppercased()
            if let ch = channel.audioChannels { s += " \(ch)" }
            parts.append(s)
        }
        return parts.isEmpty ? "N/A" : parts.joined(separator: " / ")
    }

    private func formatUptime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        var result = ""
        if h > 0 { result += "\(h)h " }
        if m > 0 { result += "\(m)m " }
        result += "\(s)s"
        return result
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.2f MB", mb)
    }
}

// MARK: - Supporting Views

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

struct StateBadge: View {
    let state: String

    private var color: Color {
        switch state {
        case "streaming": return Theme.success
        case "error": return Theme.error
        default: return Theme.warning
        }
    }

    var body: some View {
        Text(state.replacingOccurrences(of: "_", with: " "))
            .font(.caption)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

struct ClientRow: View {
    let client: ProxyClientInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.ipAddress)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                Text(client.userAgent)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let since = client.connectedSince {
                Text(formatDuration(since))
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        var result = ""
        if h > 0 { result += "\(h)h " }
        if m > 0 { result += "\(m)m " }
        result += "\(s)s"
        return result
    }
}
#endif
