//
//  DispatcharrProgram.swift
//  DispatcherPVR
//
//  Dispatcharr EPG program API model
//

import Foundation

nonisolated struct DispatcharrProgram: Decodable, Sendable {
    let id: Int
    let idWasSynthetic: Bool
    let startTime: String
    let endTime: String
    let title: String
    let subTitle: String?
    let description: String?
    let tvgId: String?
    let channel: Int?
    let season: Int?
    let episode: Int?
    let bannerURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case title
        case subTitle = "sub_title"
        case description
        case tvgId = "tvg_id"
        case channel
        case season
        case episode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // id can be Int or String from Dispatcharr
        if let intId = try? container.decode(Int.self, forKey: .id) {
            id = intId
            idWasSynthetic = false
        } else if let stringId = try? container.decode(String.self, forKey: .id),
                  let parsed = Int(stringId) {
            id = parsed
            idWasSynthetic = false
        } else {
            // Use hash of the string value as fallback
            let raw = try container.decode(String.self, forKey: .id)
            id = abs(raw.hashValue)
            idWasSynthetic = true
        }

        startTime = try container.decode(String.self, forKey: .startTime)
        endTime = try container.decode(String.self, forKey: .endTime)
        title = try container.decode(String.self, forKey: .title)
        subTitle = try container.decodeIfPresent(String.self, forKey: .subTitle)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        tvgId = try container.decodeIfPresent(String.self, forKey: .tvgId)

        // channel can also be Int or String
        if let intCh = try? container.decode(Int.self, forKey: .channel) {
            channel = intCh
        } else if let stringCh = try? container.decodeIfPresent(String.self, forKey: .channel),
                  let parsed = Int(stringCh) {
            channel = parsed
        } else {
            channel = nil
        }

        season = try container.decodeIfPresent(Int.self, forKey: .season)
        episode = try container.decodeIfPresent(Int.self, forKey: .episode)

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

    func toProgram(channelId: Int? = nil) -> Program? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        guard let startDate = formatter.date(from: startTime) ?? fallbackFormatter.date(from: startTime),
              let endDate = formatter.date(from: endTime) ?? fallbackFormatter.date(from: endTime),
              endDate > startDate else {
            return nil
        }

        return Program(
            id: id,
            name: title,
            subtitle: subTitle,
            desc: description,
            start: Int(startDate.timeIntervalSince1970),
            end: Int(endDate.timeIntervalSince1970),
            genres: nil,
            channelId: channelId ?? channel,
            season: season,
            episode: episode,
            bannerURL: bannerURL
        )
    }

}
