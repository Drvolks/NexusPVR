//
//  ServerDiscoveryService.swift
//  PVR Client
//
//  Discovers PVR servers on the local network via subnet scanning
//

import Combine
import CryptoKit
import Foundation
import Network

nonisolated struct DiscoveredServer: Identifiable, Equatable {
    let id: String // IP address
    let host: String
    let port: Int
    let serverName: String
    let requiresAuth: Bool // true if default PIN/credentials don't work
}

@MainActor
class ServerDiscoveryService: ObservableObject {
    @Published var discoveredServers: [DiscoveredServer] = []
    @Published var isScanning = false

    private var scanTask: Task<Void, Never>?
    private var credentials: (username: String, password: String)?

    func startScan(username: String = "", password: String = "") {
        guard !isScanning else { return }
        discoveredServers = []
        isScanning = true
        credentials = (!username.isEmpty && !password.isEmpty) ? (username, password) : nil

        // Demo credentials: show a fake server immediately, skip real network scan
        if username.lowercased() == "demo" && password == "demo" {
            discoveredServers = [
                DiscoveredServer(id: "demo", host: "demo", port: Brand.defaultPort, serverName: "Demo Server", requiresAuth: false)
            ]
            isScanning = false
            return
        }

        scanTask = Task {
            await performScan()
            if !Task.isCancelled {
                // If no real servers found, offer the demo server
                if discoveredServers.isEmpty {
                    discoveredServers.append(
                        DiscoveredServer(id: "demo", host: "demo", port: Brand.defaultPort, serverName: "Demo Server", requiresAuth: false)
                    )
                }
                isScanning = false
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func performScan() async {
        guard let (localIP, subnetMask) = getLocalNetwork() else {
            return
        }

        let candidates = generateCandidateIPs(localIP: localIP, subnetMask: subnetMask)
        let port = Brand.defaultPort
        let creds = credentials

        await withTaskGroup(of: DiscoveredServer?.self) { group in
            var activeTasks = 0
            let maxConcurrent = 50

            for ip in candidates {
                if Task.isCancelled { break }

                if activeTasks >= maxConcurrent {
                    if let server = await group.next() {
                        activeTasks -= 1
                        if let server {
                            discoveredServers.append(server)
                        }
                    }
                }

                group.addTask {
                    await self.probeHost(ip, port: port, credentials: creds)
                }
                activeTasks += 1
            }

            for await server in group {
                if let server {
                    discoveredServers.append(server)
                }
            }
        }
    }

    // MARK: - Network Info

    private nonisolated func getLocalNetwork() -> (ip: String, mask: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: addr.ifa_name)
            // Skip loopback and non-standard interfaces
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            // Check interface is up and not loopback
            let flags = Int32(addr.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)

                // Get subnet mask
                var maskname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if let netmask = addr.ifa_netmask,
                   getnameinfo(netmask, socklen_t(netmask.pointee.sa_len),
                               &maskname, socklen_t(maskname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let mask = String(cString: maskname)
                    return (ip, mask)
                }
            }
        }
        return nil
    }

    private nonisolated func generateCandidateIPs(localIP: String, subnetMask: String) -> [String] {
        let ipParts = localIP.split(separator: ".").compactMap { UInt32($0) }
        let maskParts = subnetMask.split(separator: ".").compactMap { UInt32($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return [] }

        let ip: UInt32 = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
        let mask: UInt32 = (maskParts[0] << 24) | (maskParts[1] << 16) | (maskParts[2] << 8) | maskParts[3]

        let network = ip & mask
        let hostBits = ~mask
        let hostCount = min(hostBits, 1023) // Cap at 1024 hosts

        var candidates: [String] = []
        for i: UInt32 in 1...hostCount {
            let candidate = network | i
            if candidate == ip { continue } // Skip our own IP
            let a = (candidate >> 24) & 0xFF
            let b = (candidate >> 16) & 0xFF
            let c = (candidate >> 8) & 0xFF
            let d = candidate & 0xFF
            candidates.append("\(a).\(b).\(c).\(d)")
        }
        return candidates
    }

    // MARK: - Probing

    private nonisolated func probeHost(_ host: String, port: Int, credentials: (username: String, password: String)?) async -> DiscoveredServer? {
        // TCP connect probe
        guard await tcpProbe(host: host, port: port) else { return nil }

        // HTTP verification
        return await httpVerify(host: host, port: port, credentials: credentials)
    }

    private nonisolated func tcpProbe(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )

            let queue = DispatchQueue(label: "discovery.probe.\(host)")
            let state = ProbeState()

            // Timeout
            queue.asyncAfter(deadline: .now() + 0.75) {
                guard state.tryResume() else { return }
                connection.cancel()
                continuation.resume(returning: false)
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    guard state.tryResume() else { return }
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guard state.tryResume() else { return }
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private nonisolated func httpVerify(host: String, port: Int, credentials: (username: String, password: String)?) async -> DiscoveredServer? {
        let baseURL = "http://\(host):\(port)"

        #if DISPATCHERPVR
        // Dispatcharr: authenticate with provided credentials via JWT token endpoint
        return await verifyDispatcharr(baseURL: baseURL, host: host, port: port, credentials: credentials)
        #else
        // NextPVR: hit session.initiate and try default PIN
        return await verifyNextPVR(baseURL: baseURL, host: host, port: port)
        #endif
    }

    #if DISPATCHERPVR
    private nonisolated func verifyDispatcharr(baseURL: String, host: String, port: Int, credentials: (username: String, password: String)?) async -> DiscoveredServer? {
        guard let credentials else { return nil }

        guard let url = URL(string: "\(baseURL)/api/accounts/token/") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3

        let body: [String: String] = ["username": credentials.username, "password": credentials.password]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            return DiscoveredServer(id: host, host: host, port: port, serverName: Brand.serverName, requiresAuth: false)
        } catch {
            return nil
        }
    }
    #else
    private nonisolated func verifyNextPVR(baseURL: String, host: String, port: Int) async -> DiscoveredServer? {
        let probeURL = "\(baseURL)\(Brand.discoveryProbePath)"
        guard let url = URL(string: probeURL) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...399).contains(httpResponse.statusCode) else {
                return nil
            }

            let serverName = parseServerName(from: data) ?? Brand.serverName
            let requiresAuth = await !tryDefaultPINAuth(baseURL: baseURL, initiateData: data)
            return DiscoveredServer(id: host, host: host, port: port, serverName: serverName, requiresAuth: requiresAuth)
        } catch {
            return nil
        }
    }
    #endif

    private nonisolated func parseServerName(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = json["serverName"] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    #if !DISPATCHERPVR
    /// Attempt login with default PIN using the session.initiate response already fetched
    private nonisolated func tryDefaultPINAuth(baseURL: String, initiateData: Data) async -> Bool {
        guard let initResponse = try? JSONDecoder().decode(SessionInitiateResponse.self, from: initiateData),
              let sid = initResponse.sid,
              let salt = initResponse.salt else {
            return false
        }

        // md5(":" + md5(PIN) + ":" + salt)
        let pinHash = md5(Brand.defaultPIN)
        let loginHash = md5(":\(pinHash):\(salt)")

        guard let loginURL = URL(string: "\(baseURL)/services/service?method=session.login&sid=\(sid)&md5=\(loginHash)&format=json") else {
            return false
        }

        var request = URLRequest(url: loginURL)
        request.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let loginResponse = try JSONDecoder().decode(SessionLoginResponse.self, from: data)
            return loginResponse.isSuccess
        } catch {
            return false
        }
    }

    private nonisolated func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    #endif
}

/// Thread-safe one-shot flag for probe continuation resumption
private nonisolated final class ProbeState: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    /// Returns true if this is the first call (i.e., we should resume). Subsequent calls return false.
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
