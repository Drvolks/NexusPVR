//
//  DispatcharrCustomProperties.swift
//  DispatcherPVR
//
//  Dispatcharr recording custom properties
//

import Foundation

nonisolated struct DispatcharrCustomProperties: Codable {
    let program: DispatcharrProgramRef?
    let season: Int?
    let episode: Int?
    let seriesBannerURL: String?

    init(program: DispatcharrProgramRef?, season: Int? = nil, episode: Int? = nil, seriesBannerURL: String? = nil) {
        self.program = program
        self.season = season
        self.episode = episode
        self.seriesBannerURL = seriesBannerURL
    }

    enum CodingKeys: String, CodingKey {
        case program
        case season
        case episode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        program = try container.decodeIfPresent(DispatcharrProgramRef.self, forKey: .program)
        season = try container.decodeIfPresent(Int.self, forKey: .season)
        episode = try container.decodeIfPresent(Int.self, forKey: .episode)

        let dynamic = try decoder.container(keyedBy: DispatcharrDynamicCodingKey.self)
        seriesBannerURL = decodeFirstDispatcharrImageField(
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
        try container.encodeIfPresent(program, forKey: .program)
        try container.encodeIfPresent(season, forKey: .season)
        try container.encodeIfPresent(episode, forKey: .episode)

        if let seriesBannerURL {
            var dynamic = encoder.container(keyedBy: DispatcharrDynamicCodingKey.self)
            try dynamic.encode(seriesBannerURL, forKey: DispatcharrDynamicCodingKey(stringValue: "poster_url")!)
        }
    }
}
