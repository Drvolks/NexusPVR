//
//  SessionInitiateResponse.swift
//  nextpvr-apple-client
//
//  NextPVR session initiation response
//

import Foundation

nonisolated struct SessionInitiateResponse: Codable {
    let sid: String?
    let salt: String?
    let stat: String?
}
