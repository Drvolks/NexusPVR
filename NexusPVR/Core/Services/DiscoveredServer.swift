//
//  DiscoveredServer.swift
//  PVR Client
//
//  Discovered PVR server on local network
//

import Foundation

nonisolated struct DiscoveredServer: Identifiable, Equatable {
    let id: String // IP address
    let host: String
    let port: Int
    let serverName: String
    let requiresAuth: Bool // true if provided PIN/credentials don't work
}
