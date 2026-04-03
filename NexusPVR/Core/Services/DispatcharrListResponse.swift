//
//  DispatcharrListResponse.swift
//  DispatcherPVR
//
//  Flexible list response that handles array, { results: [] }, or { data: [] }
//

import Foundation

nonisolated struct DispatcharrListResponse<T: Decodable>: Decodable {
    let results: [T]?
    let data: [T]?
    let count: Int?
    let next: String?

    // Handle case where response is a plain array
    private let directItems: [T]?

    var allItems: [T] {
        results ?? data ?? directItems ?? []
    }

    init(from decoder: Decoder) throws {
        // Try decoding as an object with results/data
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            results = try container.decodeIfPresent([T].self, forKey: .results)
            data = try container.decodeIfPresent([T].self, forKey: .data)
            count = try container.decodeIfPresent(Int.self, forKey: .count)
            next = try container.decodeIfPresent(String.self, forKey: .next)
            directItems = nil
        } else {
            // Try decoding as a plain array
            let singleValueContainer = try decoder.singleValueContainer()
            directItems = try singleValueContainer.decode([T].self)
            results = nil
            data = nil
            count = nil
            next = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case results, data, count, next
    }
}
