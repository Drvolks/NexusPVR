//
//  NetworkEventLog.swift
//  DispatcherPVR
//
//  Observable event log for HTTP requests to the Dispatcharr backend
//

import Foundation
import Combine

struct NetworkEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let path: String
    let statusCode: Int?
    let isSuccess: Bool
    let durationMs: Int
    let responseSize: Int
    let errorDetail: String?
}

@MainActor
final class NetworkEventLog: ObservableObject {
    static let shared = NetworkEventLog()

    @Published private(set) var events: [NetworkEvent] = []
    private let maxEvents = 200

    func log(_ event: NetworkEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    func clear() {
        events.removeAll()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var formattedLog: String {
        events.map { event in
            let time = Self.timeFormatter.string(from: event.timestamp)
            let status = event.statusCode.map { "\($0)" } ?? "ERR"
            var line = "\(time) \(event.method) \(event.path) → \(status) (\(event.durationMs)ms)"
            if let detail = event.errorDetail {
                line += "\n  \(detail)"
            }
            return line
        }.joined(separator: "\n")
    }
}
