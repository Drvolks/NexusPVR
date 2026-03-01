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

    nonisolated func log(_ event: NetworkEvent) {
        Task { @MainActor in
            self.events.append(event)
            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
            }
            #if DEBUG
            print(Self.consoleLine(for: event))
            #endif
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
            Self.consoleLine(for: event)
        }.joined(separator: "\n")
    }

    private static func consoleLine(for event: NetworkEvent) -> String {
        let time = timeFormatter.string(from: event.timestamp)
        let status = event.statusCode.map { " → \($0)" } ?? (event.isSuccess ? "" : " → ERR")
        let duration = event.durationMs > 0 ? " (\(event.durationMs)ms)" : ""
        var line = "\(time) \(event.method) \(event.path)\(status)\(duration)"
        if let detail = event.errorDetail {
            line += "\n  \(detail)"
        }
        return line
    }
}
