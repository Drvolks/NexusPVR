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
    @Published var activeCount = 0
    @Published var isLoading = false
    @Published var error: String?

    private var refreshTask: Task<Void, Never>?

    func startRefreshing(client: DispatcherClient, appState: AppState) {
        stopRefreshing()
        refreshTask = Task {
            while !Task.isCancelled {
                await refresh(client: client, appState: appState)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh(client: DispatcherClient, appState: AppState) async {
        if channels.isEmpty {
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

        isLoading = false
    }
}
#endif
