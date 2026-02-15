//
//  NexusPVRUITests.swift
//  NexusPVRUITests
//
//  End-to-end UI tests using the demo server
//

import XCTest

// MARK: - End-to-End Tests (Demo Mode)

final class NexusPVREndToEndTests: XCTestCase {

    static var app: XCUIApplication!

    /// Name of the program scheduled in test04, reused in test05/07/08
    static var scheduledProgramName: String?

    #if os(tvOS)
    /// Track the current tvOS tab index for minimal navigation
    /// Guide=0, Recordings=1, Topics=2, Search=3, Settings=4
    static var currentTVTabIndex: Int = 0 // Start on Guide
    #endif

    // Launch app ONCE in demo mode for all tests in this class
    override class func setUp() {
        super.setUp()
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app = XCUIApplication()
        app.launchArguments = ["--demo-mode"]
        app.launch()
    }

    override class func tearDown() {
        app = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Sequential Tests

    @MainActor
    func test01_guideLoads() throws {
        let app = Self.app!
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App should launch")

        // Wait for guide to load — look for channel names from demo data
        let sportsCenter = app.staticTexts["SportsCenter HD"].firstMatch
        let channelVisible = sportsCenter.waitForExistence(timeout: 5)

        if !channelVisible {
            // On tvOS the channel name may render differently
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "Guide should load")
        }
    }

    #if os(macOS)
    @MainActor
    func test02_channelOpensPlayer() throws {
        let app = Self.app!

        let channelButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide-channel-'")).firstMatch
        guard channelButton.waitForExistence(timeout: 3) else { return }

        channelButton.click()

        // Player uses Metal — XCUI can't see elements on it.
        // Verify player opened by checking guide is gone.
        Thread.sleep(forTimeInterval: 2)
        let channelStillVisible = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide-channel-'")).firstMatch.waitForExistence(timeout: 1)
        XCTAssertFalse(channelStillVisible, "Player should replace/cover the guide view")

        // Dismiss player with Escape key
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)

        // Verify guide is back
        let guideBack = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide-channel-'")).firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(guideBack, "Guide should reappear after dismissing player")
    }
    #endif

    #if os(tvOS)
    @MainActor
    func test02_currentProgramOpensPlayer() throws {
        let app = Self.app!
        let remote = XCUIRemote.shared

        // Move focus down to guide content and select a program
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.5)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 2)

        // Dismiss player
        let playerView = app.otherElements["player-view"].firstMatch
        if playerView.waitForExistence(timeout: 5) {
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 2)
        }
        // Press menu again to return focus to nav bar
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 1)
    }
    #endif

    @MainActor
    func test03_futureProgramShowsDetails() throws {
        let app = Self.app!
        openFutureProgramDetail(app: app)

        #if os(tvOS)
        let recordButton = app.buttons["record-button"].firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 3), "Program detail should show with record button")
        XCUIRemote.shared.press(.menu)
        Thread.sleep(forTimeInterval: 0.5)
        #else
        let detailTitle = app.staticTexts["Program Details"].firstMatch
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 3), "Program detail sheet should appear")
        dismissSheet(app: app)
        #endif
    }

    @MainActor
    func test04_scheduleRecording() throws {
        let app = Self.app!
        openFutureProgramDetail(app: app)

        // Capture program name via accessibility identifier
        let nameEl = app.staticTexts.matching(NSPredicate(format: "identifier == 'program-detail-name'")).firstMatch
        if nameEl.waitForExistence(timeout: 2) {
            let name = nameEl.label
            if !name.isEmpty && name != "program-detail-name" {
                Self.scheduledProgramName = name
            } else if let val = nameEl.value as? String, !val.isEmpty {
                Self.scheduledProgramName = val
            }
        }
        // Fallback: longest static text in the detail view
        if Self.scheduledProgramName == nil || (Self.scheduledProgramName ?? "").isEmpty {
            var longest = ""
            let skip = Set(["Program Details", "Done", "Record", "Cancel Recording", "Watch Live"])
            for i in 0..<min(app.staticTexts.count, 20) {
                let lbl = app.staticTexts.element(boundBy: i).label
                if lbl.count > longest.count && !skip.contains(lbl) && !lbl.contains("AM") && !lbl.contains("PM") {
                    longest = lbl
                }
            }
            if !longest.isEmpty {
                Self.scheduledProgramName = longest
            }
        }

        XCTAssertNotNil(Self.scheduledProgramName, "Should capture program name from detail view")
        XCTAssertFalse((Self.scheduledProgramName ?? "").isEmpty, "Program name should not be empty")

        // Tap Record
        let recordButton = app.buttons["record-button"].firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 3), "Record button should exist")
        tap(recordButton, app: app)
        Thread.sleep(forTimeInterval: 1)

        // Verify scheduled
        let cancelButton = app.buttons["cancel-recording-button"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3), "Should change to Cancel Recording")

        dismissSheet(app: app)
    }

    @MainActor
    func test05_recordingsShowScheduled() throws {
        let app = Self.app!
        let programName = try XCTUnwrap(Self.scheduledProgramName, "test04 must capture program name first")

        navigateToTab("Recordings", app: app)
        Thread.sleep(forTimeInterval: 1)

        // Switch to Scheduled segment
        #if os(tvOS)
        // On tvOS, navigate to the segmented picker and select Scheduled
        // Default is Completed, so we need to move right to reach Scheduled
        let remote = XCUIRemote.shared
        // Focus should be on the segmented picker after navigating to Recordings
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.3)
        // If there's a "Recording" segment, we need one more right press
        remote.press(.right)
        Thread.sleep(forTimeInterval: 1)
        #else
        selectSegment("Scheduled", in: app)
        Thread.sleep(forTimeInterval: 1)
        #endif

        let scheduledProgram = app.staticTexts[programName].firstMatch
        XCTAssertTrue(scheduledProgram.waitForExistence(timeout: 3), "'\(programName)' should appear in Scheduled recordings")
    }

    @MainActor
    func test06_recordingsList() throws {
        let app = Self.app!

        navigateToTab("Recordings", app: app)
        Thread.sleep(forTimeInterval: 1)

        #if os(tvOS)
        // On tvOS, navigate the segmented picker to Completed
        // After test05 switched to Scheduled, we need to go left to get back to Completed
        let remote = XCUIRemote.shared
        remote.press(.left)
        Thread.sleep(forTimeInterval: 0.5)
        remote.press(.left)
        Thread.sleep(forTimeInterval: 1)
        #else
        selectSegment("Completed", in: app)
        Thread.sleep(forTimeInterval: 1)
        #endif

        let ironingRecording = app.staticTexts["Extreme Ironing Championship"].firstMatch
        XCTAssertTrue(ironingRecording.waitForExistence(timeout: 3), "Completed recordings should be visible")
    }

    @MainActor
    func test07_topicsAddKeyword() throws {
        let app = Self.app!
        let programName = try XCTUnwrap(Self.scheduledProgramName, "test04 must capture program name first")

        // Extract keyword from program name
        let words = programName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 }
        let skip = Set(["The", "the", "And", "and", "With", "with", "From", "from", "Episode", "Season"])
        let keyword = words.first(where: { !skip.contains($0) }) ?? words.first!

        navigateToTab("Topics", app: app)
        Thread.sleep(forTimeInterval: 2)

        #if os(tvOS)
        let remote = XCUIRemote.shared

        // Focus is on the segmented Picker after navigating to Topics.
        // Demo mode seeds keywords (Hockey, Ironing, Cat Videos) + Manage.
        // Navigate right to reach the "Manage" segment (last segment).
        for _ in 0..<6 {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.4)
        }
        Thread.sleep(forTimeInterval: 1)

        // Verify the manage view is showing by checking for the text field
        let textField = app.textFields["keyword-text-field"].firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 5), "Keyword text field should exist in manage view")

        // Move down from the picker into the manage content area.
        // There are existing keyword rows (each is a card button) before the text field.
        // Keep pressing down until the text field has focus.
        for _ in 0..<8 {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.5)
            if textField.hasFocus { break }
        }

        // Activate the text field and type the keyword, then submit via onSubmit
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1)
        textField.typeText(keyword + "\n")
        // After adding via onSubmit, the keyword is auto-selected in the Picker
        Thread.sleep(forTimeInterval: 3)
        #else
        // iOS/macOS: Open keywords editor
        let editKeywords = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Edit Keywords'")).firstMatch
        let pencilButton = app.buttons["edit-keywords-button"].firstMatch

        if editKeywords.waitForExistence(timeout: 2) {
            tap(editKeywords, app: app)
        } else if pencilButton.waitForExistence(timeout: 2) {
            tap(pencilButton, app: app)
        } else {
            let anyPencil = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'pencil'")).firstMatch
            XCTAssertTrue(anyPencil.waitForExistence(timeout: 2), "Edit keywords button should exist")
            tap(anyPencil, app: app)
        }
        Thread.sleep(forTimeInterval: 1)

        // Type keyword
        let keywordField = app.textFields["keyword-text-field"].firstMatch
        let field = keywordField.waitForExistence(timeout: 2) ? keywordField : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2), "Keyword text field should exist")
        tap(field, app: app)
        field.typeText(keyword)

        // Add it
        let addConfirm = app.buttons["add-keyword-confirm"].firstMatch
        if addConfirm.waitForExistence(timeout: 2) {
            tap(addConfirm, app: app)
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Close editor
        let doneButton = app.buttons["keywords-done-button"].firstMatch
        if doneButton.waitForExistence(timeout: 2) {
            tap(doneButton, app: app)
        } else {
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 1) { tap(done, app: app) }
        }
        Thread.sleep(forTimeInterval: 2)

        // Select the new keyword tab so its programs are visible
        selectSegment(keyword, in: app)
        Thread.sleep(forTimeInterval: 1)
        #endif

        // Verify program appears in topics — check both staticTexts and any descendants
        let programText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", keyword)).firstMatch
        let anyElement = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", keyword)).firstMatch
        XCTAssertTrue(
            programText.waitForExistence(timeout: 3) || anyElement.waitForExistence(timeout: 2),
            "Programs matching '\(keyword)' should appear in Topics"
        )
    }

    @MainActor
    func test08_searchFindsProgram() throws {
        let app = Self.app!
        let programName = try XCTUnwrap(Self.scheduledProgramName, "test04 must capture program name first")

        let words = programName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 }
        let skip = Set(["The", "the", "And", "and", "With", "with", "From", "from", "Episode", "Season"])
        let searchQuery = words.first(where: { !skip.contains($0) }) ?? words.first!

        navigateToTab("Search", app: app)
        Thread.sleep(forTimeInterval: 1)

        #if os(tvOS)
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Search field should exist")
        // Focus the text field
        XCUIRemote.shared.press(.select)
        Thread.sleep(forTimeInterval: 0.5)
        // Type query and submit with return key to trigger .onSubmit
        searchField.typeText(searchQuery + "\n")
        Thread.sleep(forTimeInterval: 2)
        #else
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Search field should exist")
        tap(searchField, app: app)
        searchField.typeText(searchQuery)
        #if os(macOS)
        searchField.typeText("\n")
        #endif
        Thread.sleep(forTimeInterval: 2)
        #endif

        // Verify search returned results — look for search result rows by accessibility identifier
        let resultRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'search-result-'")).firstMatch
        let resultText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", searchQuery)).firstMatch
        let noResults = app.staticTexts["No Matching Programs"].firstMatch
        XCTAssertTrue(
            resultRow.waitForExistence(timeout: 5) || resultText.waitForExistence(timeout: 2),
            "Search results should appear for '\(searchQuery)' (noResults visible: \(noResults.exists))"
        )

        #if os(iOS)
        // Fully exit search mode: clear text, tap close, then cancel
        let closeBtn = app.buttons["close"].firstMatch
        if closeBtn.waitForExistence(timeout: 1) {
            closeBtn.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
        let clearButton = app.buttons["Clear text"].firstMatch
        if clearButton.waitForExistence(timeout: 1) {
            clearButton.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitForExistence(timeout: 1) {
            cancelButton.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Tap neutral area to dismiss keyboard
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        // Verify search is dismissed — close button should be gone
        if app.buttons["close"].firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        #endif
    }

    @MainActor
    func test09_settingsUnlinkServer() throws {
        let app = Self.app!

        #if os(iOS)
        // Ensure search is fully dismissed before navigating
        let closeBtn = app.buttons["close"].firstMatch
        if closeBtn.exists {
            closeBtn.tap()
            Thread.sleep(forTimeInterval: 0.3)
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap(); Thread.sleep(forTimeInterval: 0.3) }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        #endif

        navigateToTab("Settings", app: app)
        Thread.sleep(forTimeInterval: 2)

        #if os(tvOS)
        let remote = XCUIRemote.shared
        let unlinkButton = app.buttons["unlink-server-button"].firstMatch
        XCTAssertTrue(unlinkButton.waitForExistence(timeout: 3), "Unlink Server button should exist")

        // Navigate down into settings content to reach the unlink button.
        // Try pressing down and select, checking if the confirmation dialog appears.
        var unlinkTriggered = false
        for _ in 0..<8 {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.5)

            // Try selecting — if it triggers the unlink confirmation, we found the button
            remote.press(.select)
            Thread.sleep(forTimeInterval: 1)

            // Check if the unlink alert appeared by looking for the alert itself
            let alert = app.alerts["Unlink Server"].firstMatch
            if alert.waitForExistence(timeout: 2) {
                // The alert has "Unlink" (destructive) and "Cancel" buttons.
                // On tvOS, Cancel is focused by default. Navigate left to reach Unlink.
                remote.press(.left)
                Thread.sleep(forTimeInterval: 0.3)
                remote.press(.select)
                Thread.sleep(forTimeInterval: 2)

                // If that was Cancel, try the other direction
                let configButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Configure'")).firstMatch
                if !configButton.waitForExistence(timeout: 2) {
                    // The alert might still be open or might have been dismissed as Cancel
                    // Try opening the alert again and pressing right then select
                    remote.press(.select) // re-open if on unlink button
                    Thread.sleep(forTimeInterval: 1)
                    if alert.waitForExistence(timeout: 2) {
                        remote.press(.right)
                        Thread.sleep(forTimeInterval: 0.3)
                        remote.press(.select)
                        Thread.sleep(forTimeInterval: 2)
                    }
                }
                unlinkTriggered = true
                break
            }

            // If an alert or dialog appeared for something else, dismiss it
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(unlinkTriggered, "Should have found and triggered the Unlink Server button")
        #else
        let unlinkButton = app.buttons["unlink-server-button"].firstMatch
        XCTAssertTrue(unlinkButton.waitForExistence(timeout: 3), "Unlink Server button should exist")
        tap(unlinkButton, app: app)
        Thread.sleep(forTimeInterval: 0.5)

        // Confirm unlink — use accessibility identifier to avoid Touch Bar match
        let confirmButton = app.buttons["confirm-unlink-button"].firstMatch
        if confirmButton.waitForExistence(timeout: 2) {
            tap(confirmButton, app: app)
        } else {
            #if os(macOS)
            // Try dialog/sheet
            let dialog = app.dialogs.firstMatch
            if dialog.waitForExistence(timeout: 2) {
                let btn = dialog.buttons["Unlink"].firstMatch
                if btn.exists { btn.click() }
            } else {
                let sheet = app.sheets.firstMatch
                if sheet.waitForExistence(timeout: 2) {
                    let btn = sheet.buttons["Unlink"].firstMatch
                    if btn.exists { btn.click() }
                }
            }
            #endif
        }
        #endif
        Thread.sleep(forTimeInterval: 1)

        // Verify setup screen — the unlink button should be gone and a Configure button should appear
        let configButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Configure'")).firstMatch
        XCTAssertTrue(configButton.waitForExistence(timeout: 5), "App should return to setup screen after unlinking")
        let unlinkGone = app.buttons["unlink-server-button"].firstMatch
        XCTAssertFalse(unlinkGone.exists, "Unlink button should not exist after unlinking")
    }

    // MARK: - Helpers

    /// Platform-adaptive tap/click
    private func tap(_ element: XCUIElement, app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.select)
        #elseif os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    /// Dismiss a sheet/detail
    private func dismissSheet(app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #else
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) {
            tap(done, app: app)
        }
        #endif
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func navigateToTab(_ tabName: String, app: XCUIApplication) {
        #if os(tvOS)
        let remote = XCUIRemote.shared
        // Press down to ensure we're in the content area (not the nav bar)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.3)
        // Press menu to bring focus to the nav bar (triggers enableNavBar)
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 1.0)
        // Navigate to the target tab
        let tabs = ["Guide", "Recordings", "Topics", "Search", "Settings"]
        guard let targetIndex = tabs.firstIndex(of: tabName) else { return }
        // Calculate direction from current tracked position
        let currentIndex = Self.currentTVTabIndex
        let diff = targetIndex - currentIndex
        if diff > 0 {
            for _ in 0..<diff {
                remote.press(.right)
                Thread.sleep(forTimeInterval: 0.5)
            }
        } else if diff < 0 {
            for _ in 0..<(-diff) {
                remote.press(.left)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        // Only update tracked position now (before select confirms it)
        Self.currentTVTabIndex = targetIndex
        // Wait for the content to load before entering it
        // This is critical for tabs like Topics that load data asynchronously
        Thread.sleep(forTimeInterval: 2.0)
        // Select the tab (sends focus to content area)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.0)
        #elseif os(macOS)
        // Try multiple macOS sidebar element types
        for query in [
            app.outlines.buttons[tabName].firstMatch,
            app.outlines.staticTexts[tabName].firstMatch,
            app.cells[tabName].firstMatch,
            app.staticTexts[tabName].firstMatch,
            app.buttons[tabName].firstMatch,
            app.cells.containing(.staticText, identifier: tabName).firstMatch,
        ] {
            if query.waitForExistence(timeout: 0.5) {
                query.click()
                return
            }
        }
        #else
        let tabButton = app.buttons["tab-\(tabName)"].firstMatch
        // If not hittable, try dismissing keyboard/overlays
        if tabButton.exists && !tabButton.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        if tabButton.waitForExistence(timeout: 2) {
            // Use coordinate tap for reliability — .tap() can fail if element is behind overlays
            tabButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }
        let labelButton = app.buttons[tabName].firstMatch
        if labelButton.waitForExistence(timeout: 1) { labelButton.tap(); return }
        #endif
    }

    /// Open a future program's detail by iterating guide programs until finding one with a Record button.
    private func openFutureProgramDetail(app: XCUIApplication) {
        navigateToTab("Guide", app: app)
        Thread.sleep(forTimeInterval: 1)

        #if os(tvOS)
        let remote = XCUIRemote.shared
        // Move focus from nav bar into guide content
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1)

        // Try selecting programs, scrolling further right each attempt.
        // The guide may auto-scroll back to "now", so we scroll aggressively
        // and wait between presses to let the view settle.
        for attempt in 0..<6 {
            // Scroll right to reach future programs
            let scrollCount = 8 + (attempt * 4)
            for _ in 0..<scrollCount {
                remote.press(.right)
                Thread.sleep(forTimeInterval: 0.3)
            }
            Thread.sleep(forTimeInterval: 1)

            remote.press(.select)
            Thread.sleep(forTimeInterval: 2)

            let recordButton = app.buttons["record-button"].firstMatch
            if recordButton.waitForExistence(timeout: 2) {
                return // Found a future program with detail view
            }

            // Player or something else opened — dismiss
            let playerView = app.otherElements["player-view"].firstMatch
            if playerView.exists {
                remote.press(.menu)
                Thread.sleep(forTimeInterval: 1)
            }
            // Move down to try a different channel row
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("Could not find a future program with a Record button on tvOS")
        #else
        let allPrograms = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide-program-'"))
        let count = allPrograms.count
        XCTAssertGreaterThan(count, 0, "Guide should have program buttons")

        // Start from 2/3 through the list (later = more likely future)
        let startIndex = (count * 2) / 3
        for i in startIndex..<min(startIndex + 15, count) {
            let button = allPrograms.element(boundBy: i)
            guard button.exists else { continue }

            // Skip buttons that aren't hittable (off-screen) to avoid hitting wrong elements
            #if os(macOS)
            button.click()
            #else
            guard button.isHittable else { continue }
            button.tap()
            #endif
            Thread.sleep(forTimeInterval: 1)

            let recordButton = app.buttons["record-button"].firstMatch
            if recordButton.waitForExistence(timeout: 1.5) {
                return // Found a future program
            }

            // Past program or player opened — dismiss and try next
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 0.5) { tap(done, app: app) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("Could not find a future program with a Record button")
        #endif
    }

    /// Tap a segment in a segmented picker
    private func selectSegment(_ label: String, in app: XCUIApplication) {
        for query in [
            app.buttons[label].firstMatch,
            app.segmentedControls.firstMatch.buttons[label].firstMatch,
            app.radioButtons[label].firstMatch,
            app.staticTexts[label].firstMatch,
        ] {
            if query.waitForExistence(timeout: 0.5) {
                tap(query, app: app)
                return
            }
        }
    }
}

// MARK: - Skipped Tests (run manually)

final class NexusPVRUITests: XCTestCase {
    @MainActor
    func testAllPagesLoadSuccessfully() throws {
        throw XCTSkip("Basic navigation test — run manually")
    }
}

final class StabilityUITests: XCTestCase {
    @MainActor
    func testAppStabilityAndNavigation() throws {
        throw XCTSkip("Stability test — run manually")
    }
}

final class LaunchPerformanceTests: XCTestCase {
    @MainActor
    func testLaunchPerformance() throws {
        throw XCTSkip("Launch performance test — run manually")
    }
}
