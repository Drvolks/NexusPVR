//
//  Tab.swift
//  nextpvr-apple-client
//
//  Navigation tab enumeration
//

import Foundation

enum Tab: String, Identifiable {
    case guide = "Guide"
    case recordings = "Recordings"
    case topics = "Topics"
    case calendar = "Calendar"
    case search = "Search"
    #if DISPATCHERPVR
    case stats = "Status"
    #endif
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .guide: return "calendar"
        case .topics: return "star.fill"
        case .calendar: return "calendar.badge.clock"
        case .search: return "magnifyingglass"
        case .recordings: return "recordingtape"
        #if DISPATCHERPVR
        case .stats: return "chart.bar.fill"
        #endif
        case .settings: return "gear"
        }
    }

    var label: String { rawValue }

    static var allCases: [Tab] {
        allCases(userLevel: 10)
    }

    static func allCases(userLevel: Int) -> [Tab] {
        var cases: [Tab] = [.guide]
        if userLevel >= 1 { cases.append(.recordings) }
        cases.append(contentsOf: [.topics, .search])
        #if DISPATCHERPVR
        if userLevel >= 1 { cases.append(.stats) }
        #endif
        cases.append(.settings)
        return cases
    }

    #if os(iOS)
    /// Tabs shown in the iOS collapsible nav bar (search is integrated into the bar itself)
    static func iOSTabs(userLevel: Int) -> [Tab] {
        var cases: [Tab] = [.guide]
        if userLevel >= 1 { cases.append(.recordings) }
        cases.append(contentsOf: [.topics, .calendar])
        #if DISPATCHERPVR
        if userLevel >= 1 { cases.append(.stats) }
        #endif
        cases.append(.settings)
        return cases
    }
    #endif

    #if os(macOS)
    /// Tabs shown in the macOS sidebar (search is integrated into the guide floating bar)
    static func macOSTabs(userLevel: Int) -> [Tab] {
        var cases: [Tab] = [.guide]
        if userLevel >= 1 { cases.append(.recordings) }
        cases.append(contentsOf: [.topics, .calendar])
        #if DISPATCHERPVR
        if userLevel >= 1 { cases.append(.stats) }
        #endif
        cases.append(.settings)
        return cases
    }
    #endif

    #if os(tvOS)
    /// Tabs shown in the tvOS sidebar
    static func tvOSTabs(userLevel: Int) -> [Tab] {
        var cases: [Tab] = [.guide]
        if userLevel >= 1 { cases.append(.recordings) }
        cases.append(.topics)
        #if DISPATCHERPVR
        if userLevel >= 1 { cases.append(.stats) }
        #endif
        cases.append(.settings)
        return cases
    }
    #endif
}
