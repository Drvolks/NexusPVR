//
//  RecordingsFilter.swift
//  nextpvr-apple-client
//
//  Recording list filter options
//

import Foundation

enum RecordingsFilter: String, Identifiable {
    case completed = "Completed"
    case recording = "Recording"
    case scheduled = "Scheduled"

    var id: String { rawValue }
}
