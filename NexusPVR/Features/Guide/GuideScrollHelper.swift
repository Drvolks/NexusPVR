//
//  GuideScrollHelper.swift
//  nextpvr-apple-client
//
//  Helper functions for guide scroll position and text padding calculations
//  Extracted for testability
//

import Foundation

/// Helper for calculating guide scroll positions and text padding
enum GuideScrollHelper {

    /// Calculates the scroll target time (either :00 or :30 of the current hour)
    /// - Parameter currentTime: The current time
    /// - Returns: The target scroll time (:00 if minute < 30, :30 otherwise)
    static func calculateScrollTarget(currentTime: Date) -> Date {
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: currentTime)
        let currentMinute = calendar.component(.minute, from: currentTime)

        if currentMinute < 30 {
            // e.g., 9:15 -> scroll to 9:00
            return calendar.date(bySettingHour: currentHour, minute: 0, second: 0, of: currentTime) ?? currentTime
        } else {
            // e.g., 9:45 -> scroll to 9:30
            return calendar.date(bySettingHour: currentHour, minute: 30, second: 0, of: currentTime) ?? currentTime
        }
    }

    /// Calculates the scroll ID for the given time
    /// - Parameters:
    ///   - currentTime: The current time
    ///   - targetHour: The hour Date from hoursToShow array that matches the current hour
    /// - Returns: The scroll ID string (e.g., "scroll-1234567890")
    static func calculateScrollId(currentTime: Date, targetHour: Date) -> String {
        let calendar = Calendar.current
        let currentMinute = calendar.component(.minute, from: currentTime)

        // For :00, use the hour timestamp; for :30, add 1800 seconds
        let scrollTimestamp = currentMinute < 30
            ? targetHour.timeIntervalSince1970
            : targetHour.timeIntervalSince1970 + 1800

        return "scroll-\(scrollTimestamp)"
    }

    /// Calculates the leading padding for a program cell to align text with the visible scroll position
    /// - Parameters:
    ///   - programStart: The program's start time
    ///   - scrollTarget: The scroll target time (from calculateScrollTarget)
    ///   - hourWidth: The width in points of one hour in the grid
    ///   - isCurrentlyAiring: Whether the program is currently airing
    /// - Returns: The leading padding in points
    static func calculateLeadingPadding(
        programStart: Date,
        scrollTarget: Date,
        hourWidth: CGFloat,
        isCurrentlyAiring: Bool
    ) -> CGFloat {
        // Only apply padding to currently airing programs that started before scroll target
        guard isCurrentlyAiring && programStart < scrollTarget else {
            return 0
        }

        let secondsFromStart = scrollTarget.timeIntervalSince(programStart)
        let hoursFromStart = secondsFromStart / 3600
        return CGFloat(hoursFromStart) * hourWidth
    }

    /// Checks if a program is currently airing
    /// - Parameters:
    ///   - programStart: The program's start time
    ///   - programEnd: The program's end time
    ///   - currentTime: The current time to check against
    /// - Returns: True if the program is currently airing
    static func isCurrentlyAiring(programStart: Date, programEnd: Date, currentTime: Date) -> Bool {
        return currentTime >= programStart && currentTime < programEnd
    }
}
