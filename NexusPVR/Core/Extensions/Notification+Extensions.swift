//
//  Notification+Extensions.swift
//  nextpvr-apple-client
//
//  Notification names for app events
//

import Foundation

extension Notification.Name {
    static let preferencesDidSync = Notification.Name("preferencesDidSync")
    static let recordingsDidChange = Notification.Name("recordingsDidChange")
}
