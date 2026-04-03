//
//  TopShelfProgram.swift
//  PVR Client
//
//  Top shelf program model for live TV widget
//

import Foundation

struct TopShelfProgram {
    let programName: String
    let channelId: Int
    let channelName: String
    let startTime: Int
    let endTime: Int
    let desc: String?
    let genres: [String]?

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startTime)) }
    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(endTime)) }
}
