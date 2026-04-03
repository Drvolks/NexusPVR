//
//  ProxyStatusResponse.swift
//  DispatcherPVR
//
//  Proxy status API response models
//

import Foundation

nonisolated struct ProxyStatusResponse: Decodable {
    let count: Int?
    let channels: [ProxyChannelStatus]?
}

nonisolated struct ProxyChannelStatus: Decodable, Identifiable {
    var id: String { streamName }

    let streamName: String
    let state: String
    let resolution: String?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: String?
    let avgBitrate: String?
    let sourceFps: Double?
    let ffmpegSpeed: Double?
    let uptime: Double?
    let totalBytes: Int64?
    let m3uProfileName: String?
    let clientCount: Int?
    let clients: [ProxyClientInfo]?

    enum CodingKeys: String, CodingKey {
        case streamName = "stream_name"
        case state, resolution
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case audioChannels = "audio_channels"
        case avgBitrate = "avg_bitrate"
        case sourceFps = "source_fps"
        case ffmpegSpeed = "ffmpeg_speed"
        case uptime
        case totalBytes = "total_bytes"
        case m3uProfileName = "m3u_profile_name"
        case clientCount = "client_count"
        case clients
    }
}

nonisolated struct ProxyClientInfo: Decodable, Identifiable {
    var id: String { ipAddress + userAgent }

    let ipAddress: String
    let userAgent: String
    let connectedSince: Double?

    enum CodingKeys: String, CodingKey {
        case ipAddress = "ip_address"
        case userAgent = "user_agent"
        case connectedSince = "connected_since"
    }
}
