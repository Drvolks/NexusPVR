//
//  APIResponse.swift
//  nextpvr-apple-client
//
//  Generic API response
//

import Foundation

nonisolated struct APIResponse: Codable {
    let stat: String?
    let status: String?

    var isSuccess: Bool {
        let s = stat ?? status ?? ""
        return s.lowercased() == "ok"
    }
}
