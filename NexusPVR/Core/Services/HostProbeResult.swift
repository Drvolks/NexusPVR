//
//  HostProbeResult.swift
//  PVR Client
//
//  Host probe result for server discovery
//

import Foundation

nonisolated struct HostProbeResult: Equatable {
    let port: Int
    let useHTTPS: Bool
}
