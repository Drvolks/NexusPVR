//
//  Session.swift
//  nextpvr-apple-client
//
//  NextPVR session/authentication models
//

import Foundation

struct SessionInitiateResponse: Codable {
    let sid: String?
    let salt: String?
    let stat: String?
}

struct SessionLoginResponse: Codable {
    let stat: String?
    let status: String?

    var isSuccess: Bool {
        let s = stat ?? status ?? ""
        return s.lowercased() == "ok"
    }
}

struct APIResponse: Codable {
    let stat: String?
    let status: String?

    var isSuccess: Bool {
        let s = stat ?? status ?? ""
        return s.lowercased() == "ok"
    }
}

struct ServerConfig: Codable, Equatable {
    var host: String
    var port: Int
    var pin: String
    var username: String
    var password: String
    var useHTTPS: Bool

    var baseURL: String {
        let scheme = useHTTPS ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
    }

    static var `default`: ServerConfig {
        ServerConfig(host: "", port: Brand.defaultPort, pin: Brand.defaultPIN, username: "", password: "", useHTTPS: false)
    }

    var isConfigured: Bool {
        !host.isEmpty
    }

    // Coding keys with defaults for backward compatibility
    enum CodingKeys: String, CodingKey {
        case host, port, pin, username, password, useHTTPS
    }

    init(host: String, port: Int, pin: String, username: String = "", password: String = "", useHTTPS: Bool) {
        self.host = host
        self.port = port
        self.pin = pin
        self.username = username
        self.password = password
        self.useHTTPS = useHTTPS
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        pin = try container.decodeIfPresent(String.self, forKey: .pin) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        useHTTPS = try container.decode(Bool.self, forKey: .useHTTPS)
    }
}

extension ServerConfig {
    private static let storageKey = "ServerConfig"
    private static let ubiquitousStore = NSUbiquitousKeyValueStore.default

    // Legacy keys for migration
    private static let hostKey = "nextpvr_host"
    private static let portKey = "nextpvr_port"
    private static let pinKey = "nextpvr_pin"
    private static let useHTTPSKey = "nextpvr_use_https"

    nonisolated static func load() -> ServerConfig {
        // Try iCloud first
        if let data = ubiquitousStore.data(forKey: storageKey),
           let config = try? JSONDecoder().decode(ServerConfig.self, from: data),
           config.isConfigured {
            // Also save locally as backup
            saveToUserDefaults(config)
            return config
        }

        // Fall back to UserDefaults for migration or offline use
        let defaults = UserDefaults.standard

        // Try new format first
        if let data = defaults.data(forKey: storageKey),
           let config = try? JSONDecoder().decode(ServerConfig.self, from: data),
           config.isConfigured {
            // Migrate to iCloud
            config.save()
            return config
        }

        // Try legacy format for migration
        let legacyHost = defaults.string(forKey: hostKey) ?? ""
        if !legacyHost.isEmpty {
            let config = ServerConfig(
                host: legacyHost,
                port: defaults.integer(forKey: portKey) == 0 ? Brand.defaultPort : defaults.integer(forKey: portKey),
                pin: defaults.string(forKey: pinKey) ?? "",
                useHTTPS: defaults.bool(forKey: useHTTPSKey)
            )
            // Migrate to new format and iCloud
            config.save()
            // Clean up legacy keys
            defaults.removeObject(forKey: hostKey)
            defaults.removeObject(forKey: portKey)
            defaults.removeObject(forKey: pinKey)
            defaults.removeObject(forKey: useHTTPSKey)
            return config
        }

        return ServerConfig.default
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            // Save to iCloud for sync
            Self.ubiquitousStore.set(data, forKey: Self.storageKey)
            Self.ubiquitousStore.synchronize()

            // Also save locally as backup
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func saveToUserDefaults(_ config: ServerConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Call this to start observing iCloud sync changes
    static func startObservingSync(onChange: @escaping (ServerConfig) -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore,
            queue: .main
        ) { _ in
            onChange(load())
        }
    }
}
