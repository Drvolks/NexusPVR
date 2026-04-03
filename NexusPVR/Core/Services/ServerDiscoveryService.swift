//
//  ServerDiscoveryService.swift
//  PVR Client
//
//  Discovers PVR servers on the local network via subnet scanning
//

import Combine
import CryptoKit
import Foundation

@MainActor
class ServerDiscoveryService: ObservableObject {
    @Published var discoveredServers: [DiscoveredServer] = []
    @Published var isScanning = false

    private var scanTask: Task<Void, Never>?
    private var pin: String?
    private var credentials: (username: String, password: String)?
    private var apiKey: String?

    func startScan(pin: String = "", username: String = "", password: String = "", apiKey: String = "") {
        guard !isScanning else { return }
        discoveredServers = []
        isScanning = true
        self.pin = !pin.isEmpty ? pin : nil
        credentials = (!username.isEmpty && !password.isEmpty) ? (username, password) : nil
        self.apiKey = !apiKey.isEmpty ? apiKey : nil

        scanTask = Task {
            // When demo credentials are used, add the demo server as a discoverable option
            #if DISPATCHERPVR
            let isDemoCredentials = (username.lowercased() == "demo" && password == "demo")
                || apiKey.lowercased() == "demo"
            #else
            let isDemoCredentials = pin.lowercased() == "demo"
            #endif
            if isDemoCredentials {
                discoveredServers.append(DiscoveredServer(
                    id: "demo",
                    host: "demo",
                    port: Brand.defaultPort,
                    serverName: "Demo Server",
                    requiresAuth: false
                ))
            }
            await performScan()
            if !Task.isCancelled {
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
        let pin = pin
        let creds = credentials
        let key = apiKey

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
                    await self.probeHost(ip, port: port, pin: pin, credentials: creds, apiKey: key)
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

    nonisolated static func detectHostConfiguration(host rawHost: String, preferredHTTPS: Bool? = nil) async -> HostProbeResult? {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.lowercased() != "demo" else { return nil }

        let candidates = probeCandidates(preferredHTTPS: preferredHTTPS)

        for candidate in candidates {
            if await probeHostConfiguration(host: host, port: candidate.port, useHTTPS: candidate.useHTTPS) {
                return HostProbeResult(port: candidate.port, useHTTPS: candidate.useHTTPS)
            }
        }

        return nil
    }

    private nonisolated static func probeCandidates(preferredHTTPS: Bool?) -> [(port: Int, useHTTPS: Bool)] {
        switch preferredHTTPS {
        case true:
            var candidates: [(port: Int, useHTTPS: Bool)] = [(443, true)]
            if Brand.defaultPort != 443 {
                candidates.append((Brand.defaultPort, true))
            }
            return candidates
        case false:
            var candidates: [(port: Int, useHTTPS: Bool)] = [(Brand.defaultPort, false)]
            if Brand.defaultPort != 80 {
                candidates.append((80, false))
            }
            return candidates
        case nil:
            var candidates: [(port: Int, useHTTPS: Bool)] = [(Brand.defaultPort, false)]
            if Brand.defaultPort != 80 {
                candidates.append((80, false))
            }
            candidates.append((443, true))
            if Brand.defaultPort != 443 {
                candidates.append((Brand.defaultPort, true))
            }
            return candidates
        }
    }

    private nonisolated static func probeHostConfiguration(host: String, port: Int, useHTTPS: Bool) async -> Bool {
        let scheme = useHTTPS ? "https" : "http"
        let defaultPort = useHTTPS ? 443 : 80
        let baseURL = port == defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
        guard let url = URL(string: "\(baseURL)\(Brand.discoveryProbePath)") else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return isValidProbeStatus(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private nonisolated static func isValidProbeStatus(_ statusCode: Int) -> Bool {
        #if DISPATCHERPVR
        return (200...399).contains(statusCode) || statusCode == 401 || statusCode == 403 || statusCode == 405
        #else
        return (200...399).contains(statusCode)
        #endif
    }

    private nonisolated func probeHost(_ host: String, port: Int, pin: String?, credentials: (username: String, password: String)?, apiKey: String? = nil) async -> DiscoveredServer? {
        let baseURL = "http://\(host):\(port)"

        #if DISPATCHERPVR
        // Dispatcharr: authenticate with provided credentials via JWT token endpoint or API key
        return await verifyDispatcharr(baseURL: baseURL, host: host, port: port, credentials: credentials, apiKey: apiKey)
        #else
        // NextPVR: hit session.initiate and try the provided PIN when available
        return await verifyNextPVR(baseURL: baseURL, host: host, port: port, pin: pin)
        #endif
    }

    #if DISPATCHERPVR
    private nonisolated func verifyDispatcharr(baseURL: String, host: String, port: Int, credentials: (username: String, password: String)?, apiKey: String? = nil) async -> DiscoveredServer? {
        // When using API key, just confirm the host is serving HTTP on this port.
        // Any HTTP response (even 401/403) proves it's a web server.
        // The API key itself gets validated when the user actually connects.
        if let apiKey, !apiKey.isEmpty {
            // Use /api/accounts/users/me/ — accessible to all authenticated users regardless of role
            guard let url = URL(string: "\(baseURL)/api/accounts/users/me/") else { return nil }

            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 3

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    return nil
                }
                return DiscoveredServer(id: host, host: host, port: port, serverName: Brand.serverName, requiresAuth: false)
            } catch {
                return nil
            }
        }

        // Username/password: verify via JWT token endpoint
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
                // JWT failed — try XC API as fallback (password may be an XC password, not Django)
                return await verifyDispatcharrXC(baseURL: baseURL, host: host, port: port, credentials: credentials)
            }

            return DiscoveredServer(id: host, host: host, port: port, serverName: Brand.serverName, requiresAuth: false)
        } catch {
            return nil
        }
    }

    private nonisolated func verifyDispatcharrXC(baseURL: String, host: String, port: Int, credentials: (username: String, password: String)?) async -> DiscoveredServer? {
        guard let credentials else { return nil }
        let encodedUser = credentials.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? credentials.username
        let encodedPass = credentials.password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? credentials.password
        guard let xcURL = URL(string: "\(baseURL)/player_api.php?username=\(encodedUser)&password=\(encodedPass)") else { return nil }
        var xcRequest = URLRequest(url: xcURL)
        xcRequest.timeoutInterval = 3

        do {
            let (_, xcResponse) = try await URLSession.shared.data(for: xcRequest)
            guard let httpResponse = xcResponse as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            return DiscoveredServer(id: host, host: host, port: port, serverName: Brand.serverName, requiresAuth: false)
        } catch {
            return nil
        }
    }
    #else
    private nonisolated func verifyNextPVR(baseURL: String, host: String, port: Int, pin: String?) async -> DiscoveredServer? {
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
            let requiresAuth = await !tryPINAuth(baseURL: baseURL, initiateData: data, pin: pin ?? Brand.defaultPIN)
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
    /// Attempt login with the supplied PIN using the session.initiate response already fetched
    private nonisolated func tryPINAuth(baseURL: String, initiateData: Data, pin: String) async -> Bool {
        guard let initResponse = try? JSONDecoder().decode(SessionInitiateResponse.self, from: initiateData),
              let sid = initResponse.sid,
              let salt = initResponse.salt else {
            return false
        }

        // md5(":" + md5(PIN) + ":" + salt)
        let pinHash = md5(pin)
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
