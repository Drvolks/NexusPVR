//
//  LiveTVView.swift
//  nextpvr-apple-client
//
//  Live TV channel picker view
//

import SwiftUI

struct LiveTVView: View {
    @EnvironmentObject private var client: NextPVRClient
    @EnvironmentObject private var appState: AppState
    @State private var viewModel: LiveTVViewModel?
    @State private var playError: String?

    #if os(tvOS)
    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 400), spacing: Theme.spacingMD)
    ]
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: Theme.spacingMD)
    ]
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    if vm.isLoading && vm.channels.isEmpty {
                        loadingView
                    } else if let error = vm.error, vm.channels.isEmpty {
                        errorView(error)
                    } else if vm.channels.isEmpty {
                        emptyView
                    } else {
                        channelGrid(vm)
                    }
                } else {
                    loadingView
                }
            }
            .navigationTitle("Live TV")
            #if os(iOS)
            .searchable(text: Binding(
                get: { viewModel?.searchText ?? "" },
                set: { viewModel?.searchText = $0 }
            ), prompt: "Search channels")
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await viewModel?.loadChannels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .alert("Error", isPresented: .constant(playError != nil)) {
                Button("OK") { playError = nil }
            } message: {
                if let error = playError {
                    Text(error)
                }
            }
        }
        .background(Theme.background)
        .task {
            if viewModel == nil {
                viewModel = LiveTVViewModel(client: client)
            }
            await viewModel?.loadChannels()
        }
    }

    private var loadingView: some View {
        VStack(spacing: Theme.spacingMD) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.accent)
            Text("Loading channels...")
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.warning)
            Text("Unable to load channels")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await viewModel?.loadChannels() }
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "tv")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No channels available")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Configure your NextPVR server in Settings")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func channelGrid(_ vm: LiveTVViewModel) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.spacingMD) {
                ForEach(vm.filteredChannels) { channel in
                    ChannelCard(
                        channel: channel,
                        currentProgram: vm.currentProgram(for: channel)
                    )
                    .onTapGesture {
                        playChannel(channel, vm: vm)
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await vm.loadChannels()
        }
    }

    private func playChannel(_ channel: Channel, vm: LiveTVViewModel) {
        Task {
            do {
                let url = try await vm.streamURL(for: channel)
                let programName = vm.currentProgram(for: channel)?.name ?? "Live"
                appState.playStream(url: url, title: "\(channel.name) - \(programName)")
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}

// MARK: - Channel Card

struct ChannelCard: View {
    @EnvironmentObject private var client: NextPVRClient

    let channel: Channel
    let currentProgram: Program?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            // Channel icon and number
            HStack {
                CachedAsyncImage(url: client.channelIconURL(channelId: channel.id)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    Image(systemName: "tv")
                        .font(.title)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(width: Theme.iconSize, height: Theme.iconSize)

                Spacer()

                Text("\(channel.number)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.textTertiary)
            }

            // Channel name
            Text(channel.name)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            // Current program
            if let program = currentProgram {
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.name)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Theme.surfaceHighlight)
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(width: geo.size.width * program.progress())
                        }
                    }
                    .frame(height: 3)
                    .clipShape(Capsule())
                }
            } else {
                Text("No program info")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            // Play indicator
            HStack {
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding()
        .cardStyle()
    }
}

#Preview {
    LiveTVView()
        .environmentObject(NextPVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
