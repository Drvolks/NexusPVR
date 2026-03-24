//
//  RecordingStatus+Style.swift
//  NexusPVR
//
//  Shared status color and icon mappings for recording status
//

import SwiftUI

extension RecordingStatus {
    var statusColor: Color {
        switch self {
        case .pending, .conflict: return Theme.warning
        case .recording: return Theme.recording
        case .ready: return Theme.success
        case .failed, .deleted: return Theme.error
        }
    }

    var statusIcon: String {
        switch self {
        case .pending: return "clock"
        case .recording: return "record.circle"
        case .ready: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .conflict: return "exclamationmark.triangle"
        case .deleted: return "trash"
        }
    }
}
