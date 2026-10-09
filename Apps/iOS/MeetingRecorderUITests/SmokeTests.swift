import XCTest

/// Walks the app through its main paths against a real hub: pair, open a meeting, look at each tab, check off
/// an action item, write a note, record a few seconds and send them. It changes data, so point it at a hub
/// that exists for testing:
///
///     TEST_RUNNER_MR_PAIRING_CODE='mh1:127.0.0.1:8799:…' \
///     TEST_RUNNER_MR_SCREENSHOTS=/tmp/shots \
///     xcodebuild test -project MeetingRecorder.xcodeproj -scheme MeetingRecorderMobile -destination …
///
/// Without a pairing code the test is skipped. With `MR_SCREENSHOTS`, each step is saved there as a PNG.
final class SmokeTests: XCTestCase {
    private let app = XCUIApplication()
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPairBrowseAndEdit() throws {
        guard let code = ProcessInfo.processInfo.environment["MR_PAIRING_CODE"], !code.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_MR_PAIRING_CODE to a test hub's pairing code to run this.")
        }
        app.launch()
        pairIfNeeded(with: code)

        // On an iPhone the app opens on the sidebar; on an iPad the list is already beside it.
        let allMeetings = app.staticTexts["All Meetings"].firstMatch
        XCTAssertTrue(allMeetings.waitForExistence(timeout: 20), "never got past pairing")
        snapshot("sidebar")
        if app.cells.count == 0 || !app.navigationBars["All Meetings"].exists { allMeetings.tap() }
        let firstMeeting = app.cells.firstMatch
        XCTAssertTrue(firstMeeting.waitForExistence(timeout: 20), "no meetings arrived from the hub")
        snapshot("meetings")

        firstMeeting.tap()
        XCTAssertTrue(app.buttons["Summary"].waitForExistence(timeout: 10))
        snapshot("summary")

        app.buttons["Transcript"].tap()
        snapshot("transcript")

        app.buttons["Actions"].tap()
        let markDone = app.buttons["Mark as done"].firstMatch
        if markDone.waitForExistence(timeout: 5) {
            markDone.tap()
            XCTAssertTrue(app.buttons["Mark as not done"].firstMatch.waitForExistence(timeout: 5))
        }
        snapshot("actions")

        app.buttons["Notes"].tap()
        let notes = app.textViews.firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText("Checked from the UI test. ")
        snapshot("notes")

        // Give the debounced save and the push a moment to reach the hub before the app is torn down.
        sleep(5)

        // Back out to the sidebar (an iPhone has to; an iPad already shows it) and look at Settings.
        let back = app.navigationBars.buttons["BackButton"]
        while back.firstMatch.exists, !app.buttons["Settings"].exists { back.firstMatch.tap() }
        snapshot("projects")
        if app.buttons["Settings"].firstMatch.exists, app.staticTexts["Action Items"].firstMatch.exists {
            app.staticTexts["Action Items"].firstMatch.tap()
            snapshot("action-items")
            if back.firstMatch.exists { back.firstMatch.tap() }
        }
        if app.buttons["Settings"].firstMatch.exists {
            app.buttons["Settings"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Sync Now"].waitForExistence(timeout: 10))
            snapshot("settings")
        }
    }

    func testRecordingReachesTheHub() throws {
        guard let code = ProcessInfo.processInfo.environment["MR_PAIRING_CODE"], !code.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_MR_PAIRING_CODE to a test hub's pairing code to run this.")
        }
        // The first recording asks for the microphone.
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        pairIfNeeded(with: code)

        let record = app.buttons["Record"].firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 20))
        // Disabled until the first sync has brought a project for the recording to go into.
        XCTAssertTrue(record.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        record.tap()
        app.tap()   // lets the interruption monitor answer the permission alert, if there was one
        guard app.staticTexts["Recording"].waitForExistence(timeout: 15) else {
            #if targetEnvironment(simulator)
            throw XCTSkip("This simulator has no microphone to record from.")
            #else
            return XCTFail("recording never started")
            #endif
        }
        sleep(4)
        snapshot("recording")

        app.buttons["Stop and upload"].tap()
        XCTAssertTrue(app.staticTexts["Meeting"].firstMatch.waitForExistence(timeout: 10), "the recording didn't become a meeting")
        snapshot("recorded")
        // The upload belongs to the system; give it a moment before the app goes away.
        sleep(8)
        snapshot("uploaded")
    }

    /// Needs a recording named by `MR_IMPORT_FILE` (without its extension) to be in the device's Files app.
    func testImportedRecordingReachesTheHub() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let code = environment["MR_PAIRING_CODE"], !code.isEmpty, let name = environment["MR_IMPORT_FILE"] else {
            throw XCTSkip("Set TEST_RUNNER_MR_PAIRING_CODE and TEST_RUNNER_MR_IMPORT_FILE to run this.")
        }
        app.launch()
        pairIfNeeded(with: code)
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20))
        let back = app.navigationBars.buttons["BackButton"]
        while back.firstMatch.exists, !app.buttons["Add"].exists { back.firstMatch.tap() }

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Import Recording…"].tap()
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        // The picker opens on Recents, which is empty on a fresh device; the file is under Browse.
        if !file.waitForExistence(timeout: 3) {
            app.buttons["Browse"].firstMatch.tap()
            let onDevice = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'On My'")).firstMatch
            if !file.waitForExistence(timeout: 3), onDevice.exists { onDevice.tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 15), "the recording isn't in Files")
        snapshot("picker")
        file.tap()
        if app.buttons["Open"].waitForExistence(timeout: 3) { app.buttons["Open"].tap() }

        app.staticTexts["All Meetings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 15), "the import didn't become a meeting")
        snapshot("imported")
        sleep(10)
        snapshot("delivered")
    }

    private func pairIfNeeded(with code: String) {
        let field = app.textFields["pairing-code"]
        guard field.waitForExistence(timeout: 5) else { return }   // already paired
        snapshot("pairing")
        field.tap()
        field.typeText(code)
        app.buttons["Pair"].tap()
    }

    private func snapshot(_ name: String) {
        step += 1
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["MR_SCREENSHOTS"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let file = URL(fileURLWithPath: directory).appendingPathComponent(String(format: "%@-%02d-%@.png", device, step, name))
        try? image.pngRepresentation.write(to: file)
    }
}
