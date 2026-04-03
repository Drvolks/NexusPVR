//
//  SessionLoginResponse.swift
//  nextpvr-apple-client
//
//  NextPVR session login response
//

import Foundation

nonisolated struct SessionLoginResponse: Codable {
    let stat: String?
    let status: String?

    var isSuccess: Bool {
        let s = stat ?? status ?? ""
        return s.lowercased() == "ok"
    }
}
