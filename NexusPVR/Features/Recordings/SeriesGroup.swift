//
//  SeriesGroup.swift
//  nextpvr-apple-client
//
//  Series group model for recordings
//

import Foundation

struct SeriesGroup: Identifiable {
    let seriesName: String
    let recordings: [Recording]

    var id: String { seriesName }
}
