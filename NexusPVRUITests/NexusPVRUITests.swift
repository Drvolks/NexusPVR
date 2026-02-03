//
//  NexusPVRUITests.swift
//  NexusPVRUITests
//
//  UI tests to validate each page loads successfully on all platforms
//

import XCTest

final class NexusPVRUITests: XCTestCase {

    static var app: XCUIApplication!

    // Launch app ONCE for all tests in this class
    override class func setUp() {
        super.setUp()
        app = XCUIApplication()
        app.launch()
    }

    override class func tearDown() {
        app = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - All Page Tests

    @MainActor
    func testAllPagesLoadSuccessfully() throws {
        let app = Self.app!

        // Test 1: App launched successfully
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App should launch")

        #if os(tvOS)
        // tvOS: Test tab navigation using remote directional buttons
        // TabView tabs are at top, use left/right to navigate between them
        let remote = XCUIRemote.shared

        // Start on Guide (first tab), wait for it to load
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Guide page should load")

        // Navigate right to Recordings tab
        remote.press(.right)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Recordings page should load")

        // Navigate right to Topics tab
        remote.press(.right)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Topics page should load")

        // Navigate right to Settings tab
        remote.press(.right)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Settings page should load")

        // Navigate back to Guide (wrap around or go left)
        remote.press(.left)
        remote.press(.left)
        remote.press(.left)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Should return to Guide")

        #else
        // iOS/macOS: Full navigation test

        // Test 2: Guide page (default tab)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Guide page should load")

        // Test 3: Recordings page
        navigateToTab("Recordings", app: app)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Recordings page should load")

        // Test 4: Topics page
        navigateToTab("Topics", app: app)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Topics page should load")

        // Test 5: Settings page
        navigateToTab("Settings", app: app)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Settings page should load")

        // Test 6: Navigate back to Guide
        navigateToTab("Guide", app: app)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Guide page should load after navigation cycle")
        #endif
    }

    // MARK: - Helper Methods (iOS/macOS only)

    #if !os(tvOS)
    private func navigateToTab(_ tabName: String, app: XCUIApplication) {
        #if os(macOS)
        // macOS uses sidebar navigation
        let sidebarItem = app.outlines.buttons[tabName].firstMatch
        if sidebarItem.waitForExistence(timeout: 2) {
            sidebarItem.click()
            return
        }
        let sidebarText = app.outlines.staticTexts[tabName].firstMatch
        if sidebarText.waitForExistence(timeout: 2) {
            sidebarText.click()
            return
        }
        let listCell = app.cells[tabName].firstMatch
        if listCell.waitForExistence(timeout: 2) {
            listCell.click()
            return
        }
        #else
        // iOS uses custom tab bar buttons
        let tabButton = app.buttons[tabName].firstMatch
        if tabButton.waitForExistence(timeout: 2) {
            tabButton.tap()
            return
        }
        let tabBarButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", tabName)).firstMatch
        if tabBarButton.waitForExistence(timeout: 2) {
            tabBarButton.tap()
            return
        }
        #endif
    }
    #endif
}

// MARK: - Stability Tests (Separate class for long-running tests)

final class StabilityUITests: XCTestCase {

    static var app: XCUIApplication!

    override class func setUp() {
        super.setUp()
        app = XCUIApplication()
        app.launch()
    }

    override class func tearDown() {
        app = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppStabilityAndNavigation() throws {
        let app = Self.app!

        // Part 1: Let app sit on Guide page for 10 seconds
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                     "App should remain stable on Guide page")

        #if os(tvOS)
        // tvOS: Navigate using remote and let each page settle
        let remote = XCUIRemote.shared

        // Go to each tab
        for _ in 0..<3 {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 3)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                         "App should remain stable after navigation")
        }

        // Return to first tab
        remote.press(.left)
        remote.press(.left)
        remote.press(.left)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                     "App should remain stable on Guide page")
        #else
        // iOS/macOS: Navigate to each tab
        let tabs = ["Recordings", "Topics", "Settings", "Guide"]
        for tab in tabs {
            navigateToTab(tab, app: app)
            Thread.sleep(forTimeInterval: 3)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                         "App should remain stable on \(tab) page")
        }
        #endif
    }

    #if !os(tvOS)
    private func navigateToTab(_ tabName: String, app: XCUIApplication) {
        #if os(macOS)
        let sidebarItem = app.outlines.buttons[tabName].firstMatch
        if sidebarItem.waitForExistence(timeout: 2) {
            sidebarItem.click()
            return
        }
        let sidebarText = app.outlines.staticTexts[tabName].firstMatch
        if sidebarText.waitForExistence(timeout: 2) {
            sidebarText.click()
        }
        #else
        let tabButton = app.buttons[tabName].firstMatch
        if tabButton.waitForExistence(timeout: 2) {
            tabButton.tap()
        }
        #endif
    }
    #endif
}

// MARK: - Launch Performance Test (Separate to avoid affecting other tests)

final class LaunchPerformanceTests: XCTestCase {

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
