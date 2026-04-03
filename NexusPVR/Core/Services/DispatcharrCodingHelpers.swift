//
//  DispatcharrCodingHelpers.swift
//  DispatcherPVR
//
//  Shared coding helpers for Dispatcharr API models
//

import Foundation

struct DispatcharrDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
    init?(stringValue: String) { self.stringValue = stringValue }
}

func decodeFirstDispatcharrImageField(
    from container: KeyedDecodingContainer<DispatcharrDynamicCodingKey>,
    keys: [String]
) -> String? {
    for key in keys {
        guard let codingKey = DispatcharrDynamicCodingKey(stringValue: key) else { continue }
        if let value = try? container.decodeIfPresent(String.self, forKey: codingKey),
           !value.isEmpty {
            return value
        }
    }
    return nil
}
