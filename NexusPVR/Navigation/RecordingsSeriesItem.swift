//
//  RecordingsSeriesItem.swift
//  nextpvr-apple-client
//
//  Recordings series sidebar item
//

import Foundation

struct RecordingsSeriesItem: Identifiable, Hashable {
    let name: String
    let count: Int

    var id: String { name }
}
