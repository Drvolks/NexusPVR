//
//  DispatcharrRecording.swift
//  DispatcherPVR
//
//  Dispatcharr recording API model
//

import Foundation

nonisolated struct DispatcharrRecording: Decodable {
    let id: Int
    let startTime: String
    let endTime: String
    let channel: Int
    let taskId: String?
    let customProperties: DispatcharrCustomProperties?

    enum CodingKeys: String, CodingKey {
        case id
        case startTime = "start_time"
        case endTime = "end_time"
        case channel
        case taskId = "task_id"
        case customProperties = "custom_properties"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let intId = try? container.decode(Int.self, forKey: .id) {
            id = intId
        } else if let stringId = try? container.decode(String.self, forKey: .id),
                  let parsed = Int(stringId) {
            id = parsed
        } else {
            let raw = try container.decode(String.self, forKey: .id)
            id = abs(raw.hashValue)
        }

        startTime = try container.decode(String.self, forKey: .startTime)
        endTime = try container.decode(String.self, forKey: .endTime)
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        customProperties = try container.decodeIfPresent(DispatcharrCustomProperties.self, forKey: .customProperties)

        if let intCh = try? container.decode(Int.self, forKey: .channel) {
            channel = intCh
        } else if let stringCh = try? container.decode(String.self, forKey: .channel),
                  let parsed = Int(stringCh) {
            channel = parsed
        } else {
            channel = 0
        }
    }

    func toRecording() -> Recording {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let startDate = formatter.date(from: startTime) ?? ISO8601DateFormatter().date(from: startTime) ?? Date()
        let endDate = formatter.date(from: endTime) ?? ISO8601DateFormatter().date(from: endTime) ?? Date()

        let duration = Int(endDate.timeIntervalSince(startDate))
        let name = customProperties?.program?.title ?? "Recording"
        let subtitle = customProperties?.program?.subTitle
        let desc = customProperties?.program?.description
        let epgEventId = customProperties?.program?.id

        let now = Date()
        let status: String
        if endDate < now {
            status = "ready"
        } else if startDate <= now && endDate > now {
            status = "recording"
        } else {
            status = "pending"
        }

        // Check for locally stored playback position
        let playbackPosition = UserDefaults.standard.integer(forKey: "recording_position_\(id)")

        return Recording(
            id: id,
            name: name,
            subtitle: subtitle,
            desc: desc,
            startTime: Int(startDate.timeIntervalSince1970),
            duration: duration,
            channel: nil,
            channelId: channel,
            status: status,
            file: nil,
            recurring: false,
            recurringParent: nil,
            epgEventId: epgEventId,
            size: nil,
            quality: nil,
            genres: nil,
            playbackPosition: playbackPosition > 0 ? playbackPosition : nil,
            season: customProperties?.season,
            episode: customProperties?.episode,
            seriesBannerURL: customProperties?.seriesBannerURL ?? customProperties?.program?.bannerURL
        )
    }
}
