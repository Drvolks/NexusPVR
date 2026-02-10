//
//  LiveTVViewModel.swift
//  nextpvr-apple-client
//
//  View model for Live TV channel picker
//

import SwiftUI
import Combine

@MainActor
final class LiveTVViewModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var currentPrograms = [Int: Program]()
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchText = ""

    private let client: PVRClient

    init(client: PVRClient) {
        self.client = client
    }

    var filteredChannels: [Channel] {
        if searchText.isEmpty {
            return channels
        }
        return channels.filter { channel in
            channel.name.localizedCaseInsensitiveContains(searchText) ||
            String(channel.number).contains(searchText)
        }
    }

    func loadChannels() async {
        guard client.isConfigured else {
            error = "Server not configured"
            return
        }

        isLoading = true
        error = nil

        do {
            if !client.isAuthenticated {
                try await client.authenticate()
            }

            channels = try await client.getChannels()
            channels.sort { $0.number < $1.number }

            // Load current programs for each channel
            await loadCurrentPrograms()

            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func loadCurrentPrograms() async {
        let now = Date()

        await withTaskGroup(of: (Int, Program?).self) { group in
            for channel in channels.prefix(50) { // Limit to first 50 to avoid overloading
                group.addTask {
                    do {
                        let listings = try await self.client.getListings(channelId: channel.id)
                        let currentProgram = listings.first { program in
                            program.startDate <= now && program.endDate > now
                        }
                        return (channel.id, currentProgram)
                    } catch {
                        return (channel.id, nil)
                    }
                }
            }

            for await (channelId, program) in group {
                if let program {
                    currentPrograms[channelId] = program
                }
            }
        }
    }

    func currentProgram(for channel: Channel) -> Program? {
        currentPrograms[channel.id]
    }

    func streamURL(for channel: Channel) async throws -> URL {
        try await client.liveStreamURL(channelId: channel.id)
    }
}
