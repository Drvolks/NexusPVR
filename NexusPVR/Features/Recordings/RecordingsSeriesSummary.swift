//
//  RecordingsSeriesSummary.swift
//  nextpvr-apple-client
//
//  Series summary for recordings
//

import Foundation

struct RecordingsSeriesSummary: Identifiable {
    let name: String
    let active: [Recording]
    let completed: [Recording]
    let scheduled: [Recording]
    let bannerURL: String?

    var id: String { name }
    var totalCount: Int { active.count + completed.count + scheduled.count }
    var unwatchedCount: Int { completed.filter { !$0.isWatched }.count }
}
