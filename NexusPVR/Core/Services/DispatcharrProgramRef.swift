//
//  DispatcharrProgramRef.swift
//  DispatcherPVR
//
//  Dispatcharr program reference in recording custom properties
//

import Foundation

nonisolated struct DispatcharrProgramRef: Codable {
    let id: Int?
    let startTime: String?
    let endTime: String?
    let title: String?
    let subTitle: String?
    let description: String?
    let tvgId: String?
    let bannerURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case title
        case subTitle = "sub_title"
        case description
        case tvgId = "tvg_id"
    }

    init(
        id: Int?,
        startTime: String?,
        endTime: String?,
        title: String?,
        subTitle: String?,
        description: String?,
        tvgId: String?,
        bannerURL: String?
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.subTitle = subTitle
        self.description = description
        self.tvgId = tvgId
        self.bannerURL = bannerURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        startTime = try container.decodeIfPresent(String.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(String.self, forKey: .endTime)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subTitle = try container.decodeIfPresent(String.self, forKey: .subTitle)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        tvgId = try container.decodeIfPresent(String.self, forKey: .tvgId)

        let dynamic = try decoder.container(keyedBy: DispatcharrDynamicCodingKey.self)
        bannerURL = decodeFirstDispatcharrImageField(
            from: dynamic,
            keys: [
                "banner", "banner_url", "series_banner", "series_image",
                "poster", "poster_url", "artwork", "artwork_url",
                "image", "image_url", "thumbnail", "thumbnail_url"
            ]
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(subTitle, forKey: .subTitle)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(tvgId, forKey: .tvgId)
        // Keep using banner_url on outbound payloads.
        if let bannerURL {
            var dynamic = encoder.container(keyedBy: DispatcharrDynamicCodingKey.self)
            try dynamic.encode(bannerURL, forKey: DispatcharrDynamicCodingKey(stringValue: "banner_url")!)
        }
    }
}
