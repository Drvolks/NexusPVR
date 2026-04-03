//
//  RecordingStatus.swift
//  nextpvr-apple-client
//
//  Recording status enumeration
//

import Foundation

nonisolated enum RecordingStatus: String, Codable {
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

    var isPlayable: Bool {
        self == .ready || self == .recording
    }

    var isScheduled: Bool {
        self == .pending
    }
}
