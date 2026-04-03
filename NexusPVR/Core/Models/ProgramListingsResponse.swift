//
//  ProgramListingsResponse.swift
//  nextpvr-apple-client
//
//  Program listings API response
//

import Foundation

nonisolated struct ProgramListingsResponse: Decodable {
    let listings: [Program]?
}
