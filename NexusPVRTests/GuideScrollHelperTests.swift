//
//  GuideScrollHelperTests.swift
//  nextpvr-apple-clientTests
//
//  Tests for guide scroll position and text padding calculations
//

import Testing
import Foundation
@testable import NexusPVR

struct GuideScrollHelperTests {

    // MARK: - Test Helpers

    private func makeDate(hour: Int, minute: Int, second: Int = 0) -> Date {
        let calendar = Calendar.current
        let now = Date()
        return calendar.date(bySettingHour: hour, minute: minute, second: second, of: now)!
    }

    private func getMinute(from date: Date) -> Int {
        Calendar.current.component(.minute, from: date)
    }

    private func getHour(from date: Date) -> Int {
        Calendar.current.component(.hour, from: date)
    }

    // MARK: - Scroll Target Tests

    @Test("Scroll target at 9:07 should be 9:00")
    func scrollTarget_at_9_07_shouldBe_9_00() {
        let currentTime = makeDate(hour: 9, minute: 7)
        let target = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)

        #expect(getHour(from: target) == 9)
        #expect(getMinute(from: target) == 0)
    }

    @Test("Scroll target at 9:00 should be 9:00")
    func scrollTarget_at_9_00_shouldBe_9_00() {
        let currentTime = makeDate(hour: 9, minute: 0)
        let target = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)

        #expect(getHour(from: target) == 9)
        #expect(getMinute(from: target) == 0)
    }

    @Test("Scroll target at 9:29 should be 9:00")
    func scrollTarget_at_9_29_shouldBe_9_00() {
        let currentTime = makeDate(hour: 9, minute: 29)
        let target = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)

        #expect(getHour(from: target) == 9)
        #expect(getMinute(from: target) == 0)
    }

    @Test("Scroll target at 9:30 should be 9:30")
    func scrollTarget_at_9_30_shouldBe_9_30() {
        let currentTime = makeDate(hour: 9, minute: 30)
        let target = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)

        #expect(getHour(from: target) == 9)
        #expect(getMinute(from: target) == 30)
    }

    @Test("Scroll target at 9:47 should be 9:30")
    func scrollTarget_at_9_47_shouldBe_9_30() {
        let currentTime = makeDate(hour: 9, minute: 47)
        let target = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)

        #expect(getHour(from: target) == 9)
        #expect(getMinute(from: target) == 30)
    }

    @Test("Scroll target at 9:59 should be 9:30")
    func scrollTarget_at_9_59_shouldBe_9_30() {
        let currentTime = makeDate(hour: 9, minute: 59)
        let target = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)

        #expect(getHour(from: target) == 9)
        #expect(getMinute(from: target) == 30)
    }

    @Test("Scroll target at midnight (0:15) should be 0:00")
    func scrollTarget_at_0_15_shouldBe_0_00() {
        let currentTime = makeDate(hour: 0, minute: 15)
        let target = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)

        #expect(getHour(from: target) == 0)
        #expect(getMinute(from: target) == 0)
    }

    @Test("Scroll target at 23:45 should be 23:30")
    func scrollTarget_at_23_45_shouldBe_23_30() {
        let currentTime = makeDate(hour: 23, minute: 45)
        let target = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)

        #expect(getHour(from: target) == 23)
        #expect(getMinute(from: target) == 30)
    }

    // MARK: - Scroll ID Tests

    @Test("Scroll ID at 9:07 should use hour timestamp")
    func scrollId_at_9_07_shouldUseHourTimestamp() {
        let currentTime = makeDate(hour: 9, minute: 7)
        let targetHour = makeDate(hour: 9, minute: 0)
        let scrollId = GuideScrollHelper.calculateScrollId(currentTime: currentTime, targetHour: targetHour)

        #expect(scrollId == "scroll-\(targetHour.timeIntervalSince1970)")
    }

    @Test("Scroll ID at 9:47 should use hour timestamp + 1800")
    func scrollId_at_9_47_shouldUseHourTimestampPlus1800() {
        let currentTime = makeDate(hour: 9, minute: 47)
        let targetHour = makeDate(hour: 9, minute: 0)
        let scrollId = GuideScrollHelper.calculateScrollId(currentTime: currentTime, targetHour: targetHour)

        #expect(scrollId == "scroll-\(targetHour.timeIntervalSince1970 + 1800)")
    }

    @Test("Scroll ID at 9:00 should use hour timestamp (not +1800)")
    func scrollId_at_9_00_shouldUseHourTimestamp() {
        let currentTime = makeDate(hour: 9, minute: 0)
        let targetHour = makeDate(hour: 9, minute: 0)
        let scrollId = GuideScrollHelper.calculateScrollId(currentTime: currentTime, targetHour: targetHour)

        #expect(scrollId == "scroll-\(targetHour.timeIntervalSince1970)")
    }

    @Test("Scroll ID at 9:30 should use hour timestamp + 1800")
    func scrollId_at_9_30_shouldUseHourTimestampPlus1800() {
        let currentTime = makeDate(hour: 9, minute: 30)
        let targetHour = makeDate(hour: 9, minute: 0)
        let scrollId = GuideScrollHelper.calculateScrollId(currentTime: currentTime, targetHour: targetHour)

        #expect(scrollId == "scroll-\(targetHour.timeIntervalSince1970 + 1800)")
    }

    // MARK: - Leading Padding Tests - Program 7:00-10:00

    @Test("Padding for 7:00-10:00 program at 9:07 (scroll target 9:00) should be 2 hours")
    func padding_program_7_to_10_at_9_07() {
        let programStart = makeDate(hour: 7, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 7)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == true)
        #expect(padding == 400) // 2 hours * 200 = 400
    }

    @Test("Padding for 7:00-10:00 program at 9:47 (scroll target 9:30) should be 2.5 hours")
    func padding_program_7_to_10_at_9_47() {
        let programStart = makeDate(hour: 7, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 47)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == true)
        #expect(padding == 500) // 2.5 hours * 200 = 500
    }

    // MARK: - Leading Padding Tests - Program 9:00-10:00

    @Test("Padding for 9:00-10:00 program at 9:07 (scroll target 9:00) should be 0")
    func padding_program_9_to_10_at_9_07() {
        let programStart = makeDate(hour: 9, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 7)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == true)
        #expect(padding == 0) // Program starts at scroll target
    }

    @Test("Padding for 9:00-10:00 program at 9:47 (scroll target 9:30) should be 0.5 hours")
    func padding_program_9_to_10_at_9_47() {
        let programStart = makeDate(hour: 9, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 47)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == true)
        #expect(padding == 100) // 0.5 hours * 200 = 100
    }

    // MARK: - Leading Padding Tests - Program 8:30-9:30

    @Test("Padding for 8:30-9:30 program at 9:07 (scroll target 9:00) should be 0.5 hours")
    func padding_program_8_30_to_9_30_at_9_07() {
        let programStart = makeDate(hour: 8, minute: 30)
        let programEnd = makeDate(hour: 9, minute: 30)
        let currentTime = makeDate(hour: 9, minute: 7)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == true)
        #expect(padding == 100) // 0.5 hours * 200 = 100
    }

    @Test("Padding for 8:30-9:30 program at 9:00 (scroll target 9:00) should be 0.5 hours")
    func padding_program_8_30_to_9_30_at_9_00() {
        let programStart = makeDate(hour: 8, minute: 30)
        let programEnd = makeDate(hour: 9, minute: 30)
        let currentTime = makeDate(hour: 9, minute: 0)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == true)
        #expect(padding == 100) // 0.5 hours * 200 = 100
    }

    // MARK: - Leading Padding Tests - Program 8:00-9:00 (ended)

    @Test("Padding for 8:00-9:00 (ended) program at 9:07 should be 0")
    func padding_program_8_to_9_ended_at_9_07() {
        let programStart = makeDate(hour: 8, minute: 0)
        let programEnd = makeDate(hour: 9, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 7)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == false)
        #expect(padding == 0) // Not currently airing, no padding
    }

    // MARK: - Leading Padding Tests - Program 10:00-11:00 (future)

    @Test("Padding for 10:00-11:00 (future) program at 9:07 should be 0")
    func padding_program_10_to_11_future_at_9_07() {
        let programStart = makeDate(hour: 10, minute: 0)
        let programEnd = makeDate(hour: 11, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 7)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == false)
        #expect(padding == 0) // Not currently airing, no padding
    }

    // MARK: - Leading Padding Tests - Program starts after scroll target

    @Test("Padding for 9:15-10:00 program at 9:07 (scroll target 9:00) should be 0")
    func padding_program_starts_after_scroll_target() {
        let programStart = makeDate(hour: 9, minute: 15)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 7)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        // Note: This program hasn't started yet at 9:07, so it's not currently airing
        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == false)
        #expect(padding == 0)
    }

    // MARK: - Edge Cases

    @Test("Padding for program starting exactly at scroll target should be 0")
    func padding_program_starts_exactly_at_scroll_target() {
        let programStart = makeDate(hour: 9, minute: 30)
        let programEnd = makeDate(hour: 10, minute: 30)
        let currentTime = makeDate(hour: 9, minute: 45)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)
        let hourWidth: CGFloat = 200

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )
        let padding = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: hourWidth,
            isCurrentlyAiring: isAiring
        )

        #expect(getMinute(from: scrollTarget) == 30) // Scroll target is 9:30
        #expect(isAiring == true)
        #expect(padding == 0) // Program starts at scroll target
    }

    @Test("Padding calculation with different hour widths")
    func padding_with_different_hour_widths() {
        let programStart = makeDate(hour: 8, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 15)
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: currentTime)

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )

        // Test with different hour widths
        let padding100 = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: 100,
            isCurrentlyAiring: isAiring
        )
        let padding300 = GuideScrollHelper.calculateLeadingPadding(
            programStart: programStart,
            scrollTarget: scrollTarget,
            hourWidth: 300,
            isCurrentlyAiring: isAiring
        )

        #expect(isAiring == true)
        #expect(padding100 == 100) // 1 hour * 100 = 100
        #expect(padding300 == 300) // 1 hour * 300 = 300
    }

    // MARK: - Currently Airing Tests

    @Test("Program is airing when current time is within range")
    func isCurrentlyAiring_within_range() {
        let programStart = makeDate(hour: 9, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 30)

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )

        #expect(isAiring == true)
    }

    @Test("Program is airing at exact start time")
    func isCurrentlyAiring_at_start() {
        let programStart = makeDate(hour: 9, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 9, minute: 0)

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )

        #expect(isAiring == true)
    }

    @Test("Program is NOT airing at exact end time")
    func isCurrentlyAiring_at_end() {
        let programStart = makeDate(hour: 9, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 10, minute: 0)

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )

        #expect(isAiring == false)
    }

    @Test("Program is NOT airing before start")
    func isCurrentlyAiring_before_start() {
        let programStart = makeDate(hour: 9, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 8, minute: 59)

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )

        #expect(isAiring == false)
    }

    @Test("Program is NOT airing after end")
    func isCurrentlyAiring_after_end() {
        let programStart = makeDate(hour: 9, minute: 0)
        let programEnd = makeDate(hour: 10, minute: 0)
        let currentTime = makeDate(hour: 10, minute: 1)

        let isAiring = GuideScrollHelper.isCurrentlyAiring(
            programStart: programStart,
            programEnd: programEnd,
            currentTime: currentTime
        )

        #expect(isAiring == false)
    }

    // MARK: - Comprehensive Scenario Tests

    @Test("Scenario: Long movie 7:00-11:00 at different times")
    func scenario_long_movie() {
        let programStart = makeDate(hour: 7, minute: 0)
        let programEnd = makeDate(hour: 11, minute: 0)
        let hourWidth: CGFloat = 200

        // At 9:00 (scroll target 9:00)
        let time1 = makeDate(hour: 9, minute: 0)
        let target1 = GuideScrollHelper.calculateScrollTarget(currentTime: time1)
        let isAiring1 = GuideScrollHelper.isCurrentlyAiring(programStart: programStart, programEnd: programEnd, currentTime: time1)
        let padding1 = GuideScrollHelper.calculateLeadingPadding(programStart: programStart, scrollTarget: target1, hourWidth: hourWidth, isCurrentlyAiring: isAiring1)

        #expect(getHour(from: target1) == 9)
        #expect(getMinute(from: target1) == 0)
        #expect(padding1 == 400) // 2 hours

        // At 9:30 (scroll target 9:30)
        let time2 = makeDate(hour: 9, minute: 30)
        let target2 = GuideScrollHelper.calculateScrollTarget(currentTime: time2)
        let isAiring2 = GuideScrollHelper.isCurrentlyAiring(programStart: programStart, programEnd: programEnd, currentTime: time2)
        let padding2 = GuideScrollHelper.calculateLeadingPadding(programStart: programStart, scrollTarget: target2, hourWidth: hourWidth, isCurrentlyAiring: isAiring2)

        #expect(getHour(from: target2) == 9)
        #expect(getMinute(from: target2) == 30)
        #expect(padding2 == 500) // 2.5 hours

        // At 10:15 (scroll target 10:00)
        let time3 = makeDate(hour: 10, minute: 15)
        let target3 = GuideScrollHelper.calculateScrollTarget(currentTime: time3)
        let isAiring3 = GuideScrollHelper.isCurrentlyAiring(programStart: programStart, programEnd: programEnd, currentTime: time3)
        let padding3 = GuideScrollHelper.calculateLeadingPadding(programStart: programStart, scrollTarget: target3, hourWidth: hourWidth, isCurrentlyAiring: isAiring3)

        #expect(getHour(from: target3) == 10)
        #expect(getMinute(from: target3) == 0)
        #expect(padding3 == 600) // 3 hours
    }

    @Test("Scenario: Short 30-min program starting at :30")
    func scenario_short_program_at_half_hour() {
        let programStart = makeDate(hour: 9, minute: 30)
        let programEnd = makeDate(hour: 10, minute: 0)
        let hourWidth: CGFloat = 200

        // At 9:35 (scroll target 9:30)
        let time1 = makeDate(hour: 9, minute: 35)
        let target1 = GuideScrollHelper.calculateScrollTarget(currentTime: time1)
        let isAiring1 = GuideScrollHelper.isCurrentlyAiring(programStart: programStart, programEnd: programEnd, currentTime: time1)
        let padding1 = GuideScrollHelper.calculateLeadingPadding(programStart: programStart, scrollTarget: target1, hourWidth: hourWidth, isCurrentlyAiring: isAiring1)

        #expect(getMinute(from: target1) == 30)
        #expect(isAiring1 == true)
        #expect(padding1 == 0) // Program starts at scroll target

        // At 9:55 (scroll target 9:30)
        let time2 = makeDate(hour: 9, minute: 55)
        let target2 = GuideScrollHelper.calculateScrollTarget(currentTime: time2)
        let isAiring2 = GuideScrollHelper.isCurrentlyAiring(programStart: programStart, programEnd: programEnd, currentTime: time2)
        let padding2 = GuideScrollHelper.calculateLeadingPadding(programStart: programStart, scrollTarget: target2, hourWidth: hourWidth, isCurrentlyAiring: isAiring2)

        #expect(getMinute(from: target2) == 30)
        #expect(isAiring2 == true)
        #expect(padding2 == 0) // Program still starts at scroll target
    }
}
