//
//  NexusPVRUITests.swift
//  NexusPVRUITests
//
//  Cross-platform UI coverage for the demo experience.
//

import XCTest

final class NexusPVRUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(macOS)
        throw XCTSkip("macOS navigation and guide content are not exposed to XCUI reliably yet; run this suite on iOS/tvOS until additional accessibility hooks land.")
        #endif
    }

    @MainActor
    func testGuideLoadsDemoData() throws {
        let app = launchApp()

        XCTAssertTrue(waitForGuideContent(in: app), "Guide should expose channels or programs")
    }

    @MainActor
    func testLivePlaybackCanOpenAndClose() throws {
        let app = launchApp()
        navigateToTab("Guide", app: app)

        #if os(tvOS)
        let remote = XCUIRemote.shared
        remote.press(.down)
        pause(1.0)
        remote.press(.select)
        #else
        let channelButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide-channel-'")).firstMatch
        XCTAssertTrue(channelButton.waitForExistence(timeout: 5), "Expected at least one playable guide channel")
        activate(channelButton, app: app)
        #endif

        XCTAssertTrue(app.otherElements["player-view"].waitForExistence(timeout: 10), "Player should open from guide")
        dismissPlayer(app: app)
        XCTAssertTrue(waitForGuideContent(in: app), "Guide should be visible after player dismissal")
    }

    @MainActor
    func testSchedulingFromGuideAppearsInScheduledRecordings() throws {
        let app = launchApp()
        let scheduledProgramName = try openFutureProgramDetailAndCaptureName(app: app)

        let recordButton = app.buttons["record-button"].firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5), "Future program detail should offer recording")
        activate(recordButton, app: app)
        XCTAssertTrue(app.buttons["cancel-recording-button"].waitForExistence(timeout: 5), "Recording should switch to cancellable state")

        #if os(macOS)
        return
        #else
        dismissPresentedDetail(app: app)
        navigateToTab("Recordings", app: app)
        selectRecordingsFilter("Scheduled", in: app)

        let scheduledRecording = app.staticTexts[scheduledProgramName].firstMatch
        XCTAssertTrue(scheduledRecording.waitForExistence(timeout: 8), "'\(scheduledProgramName)' should appear in Scheduled recordings")
        #endif
    }

    #if !os(macOS)
    @MainActor
    func testCompletedRecordingsShowDemoFixtures() throws {
        let app = launchApp()
        navigateToTab("Recordings", app: app)
        selectRecordingsFilter("Completed", in: app)

        XCTAssertTrue(app.staticTexts["Extreme Ironing Championship"].firstMatch.waitForExistence(timeout: 8))
    }
    #endif

    #if !os(macOS)
    @MainActor
    func testTopicsCanAddKeywordAndRevealMatchingPrograms() throws {
        let app = launchApp()
        let futureProgramName = try openFutureProgramDetailAndCaptureName(app: app)
        let keyword = try XCTUnwrap(extractUsefulKeyword(from: futureProgramName))

        dismissPresentedDetail(app: app)
        navigateToTab("Topics", app: app)

        #if os(tvOS)
        let remote = XCUIRemote.shared
        let keywordField = app.textFields["keyword-text-field"].firstMatch

        for _ in 0..<6 {
            remote.press(.right)
            pause(0.4)
        }
        XCTAssertTrue(keywordField.waitForExistence(timeout: 5), "Manage keyword field should be reachable on tvOS")

        for _ in 0..<8 where !keywordField.hasFocus {
            remote.press(.down)
            pause(0.4)
        }

        remote.press(.select)
        pause(0.8)
        keywordField.typeText(keyword + "\n")
        pause(2.5)
        #else
        openKeywordEditor(app: app)

        let keywordField = app.textFields["keyword-text-field"].firstMatch
        XCTAssertTrue(keywordField.waitForExistence(timeout: 5))
        activate(keywordField, app: app)
        keywordField.typeText(keyword)

        let addButton = app.buttons["add-keyword-confirm"].firstMatch
        if addButton.waitForExistence(timeout: 2) {
            activate(addButton, app: app)
        }
        pause(0.5)
        dismissKeywordEditor(app: app)
        pause(1.0)

        selectKeywordTab(keyword, in: app)
        #endif

        let matchingTopicRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'topic-program-'"))
            .firstMatch
        let matchingProgramText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", keyword)).firstMatch

        XCTAssertTrue(
            matchingTopicRow.waitForExistence(timeout: 8) || matchingProgramText.waitForExistence(timeout: 3),
            "Topics should display programs matching '\(keyword)'"
        )
    }
    #endif

    @MainActor
    func testSearchFindsProgramsAndShowsDetails() throws {
        let app = launchApp()
        #if !os(macOS)
        navigateToTab("Guide", app: app)
        #endif

        #if os(tvOS)
        let remote = XCUIRemote.shared
        remote.press(.left)
        pause(1.0)

        let searchField = app.textFields["search-view-field"].firstMatch
        if !searchField.exists {
            for _ in 0..<5 where !app.textFields.firstMatch.exists {
                remote.press(.down)
                pause(0.3)
            }
        }
        let effectiveField = searchField.exists ? searchField : app.textFields.firstMatch
        XCTAssertTrue(effectiveField.waitForExistence(timeout: 5), "tvOS search field should be present")
        for _ in 0..<5 where !effectiveField.hasFocus {
            remote.press(.down)
            pause(0.3)
        }
        remote.press(.select)
        pause(0.5)
        effectiveField.typeText("Ironing\n")
        #else
        let searchField = app.textFields["global-search-field"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Global search field should be visible")
        activate(searchField, app: app)
        searchField.typeText("Ironing\n")
        #endif

        let resultRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'search-result-'"))
            .firstMatch
        XCTAssertTrue(resultRow.waitForExistence(timeout: 8), "Expected at least one search result for demo data")

        activate(resultRow, app: app)
        XCTAssertTrue(app.staticTexts["program-detail-name"].firstMatch.waitForExistence(timeout: 5))
    }

    #if os(iOS)
    @MainActor
    func testCalendarIsReachableFromTopics() throws {
        let app = launchApp()

        navigateToTab("Topics", app: app)
        let calendarButton = app.buttons["calendar-button"].firstMatch
        XCTAssertTrue(calendarButton.waitForExistence(timeout: 5), "Topics should expose the calendar shortcut")
        activate(calendarButton, app: app)

        XCTAssertTrue(
            app.segmentedControls.firstMatch.waitForExistence(timeout: 8) ||
            app.buttons["Day"].firstMatch.waitForExistence(timeout: 2) ||
            app.buttons["Week"].firstMatch.waitForExistence(timeout: 2),
            "Calendar should open successfully"
        )
    }
    #endif

    #if !os(macOS)
    @MainActor
    func testSettingsCanUnlinkServer() throws {
        let app = launchApp()
        navigateToTab("Settings", app: app)

        let unlinkButton = app.buttons["unlink-server-button"].firstMatch
        XCTAssertTrue(unlinkButton.waitForExistence(timeout: 5), "Settings should expose server unlinking")

        #if os(tvOS)
        let remote = XCUIRemote.shared
        for _ in 0..<8 {
            if unlinkButton.hasFocus { break }
            remote.press(.down)
            pause(0.4)
        }
        remote.press(.select)
        pause(1.0)
        remote.press(.left)
        pause(0.3)
        remote.press(.select)
        #else
        activate(unlinkButton, app: app)
        let confirmButton = app.buttons["confirm-unlink-button"].firstMatch
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "Unlink confirmation should appear")
        activate(confirmButton, app: app)
        #endif

        let configureButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Configure Server Manually'")).firstMatch
        XCTAssertTrue(configureButton.waitForExistence(timeout: 8), "App should return to setup after unlinking")
    }
    #endif

    // MARK: - App Launch

    @MainActor
    private func launchApp() -> XCUIApplication {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif

        let app = XCUIApplication()
        app.launchArguments = ["--demo-mode"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }

    // MARK: - Navigation

    private func navigateToTab(_ tabName: String, app: XCUIApplication) {
        #if os(tvOS)
        let remote = XCUIRemote.shared
        remote.press(.menu)
        pause(1.0)

        #if DISPATCHERPVR
        let tabs = ["Guide", "Recordings", "Topics", "Stats", "Settings"]
        #else
        let tabs = ["Guide", "Recordings", "Topics", "Settings"]
        #endif

        guard let targetIndex = tabs.firstIndex(of: tabName) else { return }
        for _ in 0..<targetIndex {
            remote.press(.right)
            pause(0.4)
        }
        remote.press(.select)
        pause(1.2)
        #elseif os(macOS)
        let effectiveTab = tabName == "Search" ? "Guide" : tabName
        let candidates: [XCUIElement] = [
            app.outlines.buttons[effectiveTab].firstMatch,
            app.outlines.staticTexts[effectiveTab].firstMatch,
            app.cells[effectiveTab].firstMatch,
            app.staticTexts[effectiveTab].firstMatch,
            app.buttons[effectiveTab].firstMatch,
            app.cells.containing(.staticText, identifier: effectiveTab).firstMatch,
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: 0.5) {
            candidate.click()
            pause(0.8)
            return
        }
        XCTFail("Could not navigate to macOS tab '\(effectiveTab)'")
        #else
        if tabName == "Search" {
            navigateToTab("Guide", app: app)
            return
        }

        let expandButton = app.buttons["nav-expand-button"].firstMatch
        XCTAssertTrue(expandButton.waitForExistence(timeout: 5), "Expected floating navigation button")
        expandButton.tap()
        pause(0.5)

        let tabButton = app.buttons["tab-\(tabName)"].firstMatch
        XCTAssertTrue(tabButton.waitForExistence(timeout: 5), "Expected tab button for '\(tabName)'")
        tabButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pause(1.0)
        #endif
    }

    // MARK: - Scenario Helpers

    private func waitForGuideContent(in app: XCUIApplication) -> Bool {
        waitForCondition(timeout: 10) {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide-program-'")).count > 0 ||
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide-channel-'")).count > 0 ||
            app.staticTexts["SportsCenter HD"].exists
        }
    }

    private func openFutureProgramDetailAndCaptureName(app: XCUIApplication) throws -> String {
        navigateToTab("Guide", app: app)
        XCTAssertTrue(waitForGuideContent(in: app), "Guide content should be loaded before opening details")

        #if os(tvOS)
        let remote = XCUIRemote.shared
        remote.press(.down)
        pause(1.0)

        for attempt in 0..<6 {
            let horizontalMoves = 8 + (attempt * 4)
            for _ in 0..<horizontalMoves {
                remote.press(.right)
                pause(0.25)
            }

            remote.press(.select)
            pause(1.5)

            let recordButton = app.buttons["record-button"].firstMatch
            if recordButton.waitForExistence(timeout: 2) {
                let detailName = app.staticTexts["program-detail-name"].firstMatch
                XCTAssertTrue(detailName.waitForExistence(timeout: 2))
                return detailName.label
            }

            if app.otherElements["player-view"].exists {
                dismissPlayer(app: app)
            } else {
                remote.press(.menu)
                pause(0.5)
            }

            remote.press(.down)
            pause(0.4)
        }

        XCTFail("Could not locate a future program with recording controls on tvOS")
        throw XCTSkip("Future program detail unavailable")
        #else
        let programButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide-program-'"))
        XCTAssertTrue(waitForCondition(timeout: 5) { programButtons.count > 0 })

        let count = programButtons.count
        let startIndex = max(0, (count * 2) / 3)

        for index in startIndex..<min(startIndex + 30, count) {
            let button = programButtons.element(boundBy: index)
            guard button.exists else { continue }

            #if os(macOS)
            button.click()
            #else
            let frame = button.frame
            guard frame.width > 1, frame.height > 1 else { continue }
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            #endif
            pause(1.0)

            let recordButton = app.buttons["record-button"].firstMatch
            if recordButton.waitForExistence(timeout: 1.5) {
                let detailName = app.staticTexts["program-detail-name"].firstMatch
                XCTAssertTrue(detailName.waitForExistence(timeout: 2))
                let label = detailName.label.isEmpty ? (detailName.value as? String ?? "") : detailName.label
                XCTAssertFalse(label.isEmpty)
                return label
            }

            dismissPresentedDetail(app: app)
            pause(0.3)
        }

        XCTFail("Could not locate a future program with recording controls")
        throw XCTSkip("Future program detail unavailable")
        #endif
    }

    private func openKeywordEditor(app: XCUIApplication) {
        let editButton = app.buttons["edit-keywords-button"].firstMatch
        if editButton.waitForExistence(timeout: 2) {
            activate(editButton, app: app)
            return
        }

        let editByLabel = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Edit Keywords'")).firstMatch
        XCTAssertTrue(editByLabel.waitForExistence(timeout: 5), "Expected a way to edit keywords")
        activate(editByLabel, app: app)
    }

    private func dismissKeywordEditor(app: XCUIApplication) {
        let doneButton = app.buttons["keywords-done-button"].firstMatch
        if doneButton.waitForExistence(timeout: 2) {
            activate(doneButton, app: app)
            return
        }
        dismissPresentedDetail(app: app)
    }

    private func dismissPresentedDetail(app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        pause(0.8)
        #else
        let doneButton = app.buttons["Done"].firstMatch
        if doneButton.waitForExistence(timeout: 2) {
            activate(doneButton, app: app)
            pause(0.8)
            return
        }
        #if os(macOS)
        app.typeKey(.escape, modifierFlags: [])
        pause(0.8)
        #endif
        #endif
    }

    private func dismissPlayer(app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        pause(1.0)
        #else
        let closeButton = app.buttons["player-close-button"].firstMatch
        if closeButton.waitForExistence(timeout: 2) {
            activate(closeButton, app: app)
        } else {
            #if os(macOS)
            app.typeKey(.escape, modifierFlags: [])
            #endif
        }
        pause(1.0)
        #endif
    }

    private func selectRecordingsFilter(_ filter: String, in app: XCUIApplication) {
        #if os(tvOS)
        let remote = XCUIRemote.shared
        let picker = app.segmentedControls["recordings-filter"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Expected recordings filter control")

        let labels = picker.buttons.allElementsBoundByIndex.map(\.label)
        guard let targetIndex = labels.firstIndex(of: filter) else {
            XCTFail("Could not locate recordings filter '\(filter)'")
            return
        }

        remote.press(.up)
        pause(0.4)
        let currentIndex = labels.firstIndex(where: { picker.buttons.element(boundBy: $0).hasFocus }) ?? 0
        let steps = targetIndex - currentIndex
        let direction: XCUIRemote.Button = steps >= 0 ? .right : .left
        for _ in 0..<abs(steps) {
            remote.press(direction)
            pause(0.25)
        }
        pause(0.8)
        #elseif os(iOS)
        let filterMenu = app.buttons["recordings-filter"].firstMatch
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 5))
        activate(filterMenu, app: app)
        let option = app.buttons[filter].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        activate(option, app: app)
        pause(0.8)
        #else
        selectSegment(filter, in: app)
        #endif
    }

    private func selectKeywordTab(_ keyword: String, in app: XCUIApplication) {
        #if os(iOS)
        let keywordMenu = app.buttons["keyword-tabs"].firstMatch
        XCTAssertTrue(keywordMenu.waitForExistence(timeout: 5))
        activate(keywordMenu, app: app)
        let option = app.buttons[keyword].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        activate(option, app: app)
        pause(0.8)
        #elseif os(macOS)
        selectSegment(keyword, in: app)
        #endif
    }

    private func selectSegment(_ label: String, in app: XCUIApplication) {
        let candidates: [XCUIElement] = [
            app.buttons[label].firstMatch,
            app.segmentedControls.firstMatch.buttons[label].firstMatch,
            app.radioButtons[label].firstMatch,
            app.staticTexts[label].firstMatch,
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: 0.5) {
            activate(candidate, app: app)
            pause(0.8)
            return
        }

        XCTFail("Could not select segment '\(label)'")
    }

    private func extractUsefulKeyword(from text: String) -> String? {
        let skip = Set(["the", "and", "with", "from", "episode", "season", "special", "live"])
        return text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { token in
                token.count >= 4 && !skip.contains(token.lowercased())
            }
    }

    // MARK: - Interaction

    private func activate(_ element: XCUIElement, app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.select)
        #elseif os(macOS)
        element.click()
        #else
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        #endif
    }

    // MARK: - Waiting

    private func waitForCondition(timeout: TimeInterval, pollInterval: TimeInterval = 0.2, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    private func pause(_ duration: TimeInterval) {
        Thread.sleep(forTimeInterval: duration)
    }
}
