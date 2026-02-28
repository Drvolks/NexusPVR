//
//  StatsViewModel.swift
//  DispatcherPVR
//
//  View model for proxy stream status monitoring
//

#if DISPATCHERPVR
import Foundation
import Combine

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var channels: [ProxyChannelStatus] = []
    @Published var m3uAccounts: [M3UAccount] = []
    @Published var activeCount = 0
    @Published var isLoading = false
    @Published var error: String?

    private var refreshTask: Task<Void, Never>?

    func startRefreshing(client: DispatcherClient, appState: AppState) {
        stopRefreshing()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(client: client, appState: appState)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh(client: DispatcherClient, appState: AppState) async {
        if channels.isEmpty && m3uAccounts.isEmpty {
            isLoading = true
        }
        error = nil

        do {
            let status = try await client.getProxyStatus()
            channels = status.channels ?? []
            activeCount = status.count ?? channels.count
            appState.activeStreamCount = activeCount
        } catch {
            self.error = error.localizedDescription
        }

        do {
            let accounts = try await client.getM3UAccounts()
            m3uAccounts = accounts.filter { $0.isActive && !$0.locked }
            appState.hasM3UErrors = m3uAccounts.contains { $0.status != "success" }
        } catch {
            // Non-critical — M3U status is informational only
        }

        isLoading = false
    }
}
#endif
