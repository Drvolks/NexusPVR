//
//  RecurringRecordingListResponse.swift
//  nextpvr-apple-client
//
//  Recurring recording list API response
//

import Foundation

nonisolated struct RecurringRecordingListResponse: Decodable {
    let recurrings: [RecurringRecording]?
}
