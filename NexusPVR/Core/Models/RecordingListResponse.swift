//
//  RecordingListResponse.swift
//  nextpvr-apple-client
//
//  Recording list API response
//

import Foundation

nonisolated struct RecordingListResponse: Codable {
    let recordings: [Recording]?
}
