//
//  M3UAccount.swift
//  DispatcherPVR
//
//  M3U account model
//

import Foundation

nonisolated struct M3UAccount: Decodable, Identifiable {
    let id: Int
    let name: String
    let serverUrl: String
    let status: String
    let updatedAt: String?
    let isActive: Bool
    let locked: Bool
    let accountType: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, locked
        case serverUrl = "server_url"
        case updatedAt = "updated_at"
        case isActive = "is_active"
        case accountType = "account_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // id can be Int or String
        if let intId = try? container.decode(Int.self, forKey: .id) {
            id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id),
                  let parsed = Int(stringId) {
            id = parsed
        } else {
            let raw = try container.decode(String.self, forKey: .id)
            id = abs(raw.hashValue)
        }

        name = (try? container.decode(String.self, forKey: .name)) ?? "Unknown"
        serverUrl = (try? container.decode(String.self, forKey: .serverUrl)) ?? ""
        status = (try? container.decode(String.self, forKey: .status)) ?? "unknown"
        updatedAt = try? container.decode(String.self, forKey: .updatedAt)
        accountType = try? container.decode(String.self, forKey: .accountType)

        // is_active can be Bool or Int (0/1)
        if let boolVal = try? container.decode(Bool.self, forKey: .isActive) {
            isActive = boolVal
        } else if let intVal = try? container.decode(Int.self, forKey: .isActive) {
            isActive = intVal != 0
        } else {
            isActive = true
        }

        // locked can be Bool or Int (0/1)
        if let boolVal = try? container.decode(Bool.self, forKey: .locked) {
            locked = boolVal
        } else if let intVal = try? container.decode(Int.self, forKey: .locked) {
            locked = intVal != 0
        } else {
            locked = false
        }
    }
}
