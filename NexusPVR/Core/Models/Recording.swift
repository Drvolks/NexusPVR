//
//  Recording.swift
//  nextpvr-apple-client
//
//  NextPVR recording model
//

import Foundation

enum RecordingStatus: String, Codable {
    case pending = "pending"
    case recording = "recording"
    case ready = "ready"
    case failed = "failed"
    case conflict = "conflict"
    case deleted = "deleted"

    var displayName: String {
        switch self {
        case .pending: return "Scheduled"
        case .recording: return "Recording"
        case .ready: return "Completed"
        case .failed: return "Failed"
        case .conflict: return "Conflict"
        case .deleted: return "Deleted"
        }
    }

    var isCompleted: Bool {
        self == .ready
    }

    var isScheduled: Bool {
        self == .pending
    }
}

struct Recording: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let subtitle: String?
    let desc: String?
    let startTime: Int? // Unix timestamp
    let duration: Int?  // seconds
    let channel: String?
    let channelId: Int?
    let status: String?
    let file: String?
    let recurring: Bool?
    let recurringParent: Int?
    let epgEventId: Int?
    let size: Int64?
    let quality: String?
    let genres: [String]?
    let playbackPosition: Int?  // Resume position in seconds

    var startDate: Date? {
        guard let startTime else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(startTime))
    }

    var endDate: Date? {
        guard let startDate, let duration else { return nil }
        return startDate.addingTimeInterval(TimeInterval(duration))
    }

    var durationMinutes: Int? {
        guard let duration else { return nil }
        return duration / 60
    }

    var recordingStatus: RecordingStatus {
        guard let status else { return .pending }
        return RecordingStatus(rawValue: status) ?? .pending
    }

    var fileSizeFormatted: String? {
        guard let size else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    // Memberwise initializer for creating instances directly
    init(id: Int, name: String, subtitle: String? = nil, desc: String? = nil,
         startTime: Int? = nil, duration: Int? = nil, channel: String? = nil,
         channelId: Int? = nil, status: String? = nil, file: String? = nil,
         recurring: Bool? = nil, recurringParent: Int? = nil, epgEventId: Int? = nil,
         size: Int64? = nil, quality: String? = nil, genres: [String]? = nil,
         playbackPosition: Int? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.desc = desc
        self.startTime = startTime
        self.duration = duration
        self.channel = channel
        self.channelId = channelId
        self.status = status
        self.file = file
        self.recurring = recurring
        self.recurringParent = recurringParent
        self.epgEventId = epgEventId
        self.size = size
        self.quality = quality
        self.genres = genres
        self.playbackPosition = playbackPosition
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case subtitle
        case desc
        case startTime
        case duration
        case channel
        case channelId
        case status
        case file
        case recurring
        case recurringParent
        case epgEventId
        case size
        case quality
        case genres
        case playbackPosition
    }
}

struct RecordingListResponse: Codable {
    let recordings: [Recording]?
}

extension Recording {
    static var preview: Recording {
        Recording(
            id: 1,
            name: "Sample Recording",
            subtitle: "Episode 1",
            desc: "A sample recording for preview purposes.",
            startTime: Int(Date().addingTimeInterval(-3600).timeIntervalSince1970),
            duration: 3600,
            channel: "ABC",
            channelId: 1,
            status: "Ready",
            file: "/recordings/sample.ts",
            recurring: false,
            recurringParent: nil,
            epgEventId: 12345,
            size: 2_500_000_000,
            quality: "HD",
            genres: ["Drama"]
        )
    }

    static var scheduledPreview: Recording {
        Recording(
            id: 2,
            name: "Upcoming Show",
            subtitle: nil,
            desc: "A scheduled recording.",
            startTime: Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
            duration: 1800,
            channel: "NBC",
            channelId: 2,
            status: "Pending",
            file: nil,
            recurring: true,
            recurringParent: 100,
            epgEventId: 12346,
            size: nil,
            quality: nil,
            genres: ["Comedy"]
        )
    }
}
