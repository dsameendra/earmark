import AppKit
import XCTest

/// Deterministic mock-service flows. Never requests TCC permissions or downloads real models.
@MainActor
final class EarmarkUITests: XCTestCase {

    private func launch(appearance: String, width: Int = 1440, height: Int = 900, arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-UseMocks", "-ApplePersistenceIgnoreState", "YES", "-EarmarkTestAppearance", appearance,
                "-EarmarkTestWidth", String(width), "-EarmarkTestHeight", String(height),
            ] + arguments
        app.launch()
        app.activate()
        // XCTest launches the menu-bar app without the Finder reopen event. Open its main scene explicitly.
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuBarItems["Window"].menuItems["Earmark"].click()
        let ready = app.buttons["sidebar.home"].waitForExistence(timeout: 15)
        if !ready { print(app.debugDescription) }
        XCTAssertTrue(ready)
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String, window: XCUIElement? = nil) {
        // M8 arrivals last at most 500 ms. Screenshots must show the resting layout, not an intermediate animation frame.
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: (window ?? app.windows.firstMatch).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Full-screen capture so popovers (separate windows) are included.
    private func captureScreen(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLightScreensAndEditorExport() throws { try screens(appearance: "light") }
    func testDarkScreensAndEditorExport() throws { try screens(appearance: "dark") }

    private func screens(appearance: String) throws {
        let app = launch(appearance: appearance)
        defer { app.terminate() }
        let sections = ["home", "queue", "meetings", "live", "library", "recentlyDeleted"]
        for (index, section) in sections.enumerated() {
            app.typeKey(String(index + 1), modifierFlags: .command)
            XCTAssertTrue(app.buttons["sidebar.\(section)"].waitForExistence(timeout: 5))
            capture(app, "\(section)-\(appearance)-1440x900")
            assertSidebarLabelsDrawn(app, dark: appearance == "dark")
        }
        app.typeKey("1", modifierFlags: .command)
        let recent = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "home.recent.", "Weekly sync")
        ).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.click()
        XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 10))
        capture(app, "editor-\(appearance)-1440x900")
        app.buttons["editor.translation"].click()
        captureScreen("translate-popover-\(appearance)")
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["editor.speakers"].click()
        XCTAssertTrue(app.textFields["editor.speakers.newName"].waitForExistence(timeout: 5))
        captureScreen("speakers-popover-\(appearance)")
        app.typeKey(.escape, modifierFlags: [])
        app.menuButtons["editor.more"].click()
        app.menuItems["Bookmarks and highlights"].click()
        XCTAssertTrue(app.staticTexts["Bookmarks & Highlights"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.menuButtons["editor.more"].click()
        app.menuItems["View options"].click()
        XCTAssertTrue(app.descendants(matching: .any)["Customize for this transcript only"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["editor.export"].click()
        let srt = app.buttons["export.format.srt"]
        XCTAssertTrue(srt.waitForExistence(timeout: 5))
        srt.click()
        XCTAssertTrue(app.buttons["export.save"].exists)
        let presetName = app.textFields["export.presetName"]
        if presetName.waitForExistence(timeout: 3) {
            presetName.click()
        }
        capture(app, "export-\(appearance)")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["Quick open"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Weekly")
        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "quickOpen.result.", "Weekly sync")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        app.windows["main"].coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.16)).click()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 4), .completed, "Clicking outside Search must dismiss it")
    }

    func testNarrowInspectorAndAllOnboardingSteps() throws {
        let app = launch(appearance: "light", width: 960, height: 600)
        defer { app.terminate() }
        let recent = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "home.recent.", "Weekly sync")
        ).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.click()
        Thread.sleep(forTimeInterval: 1)
        capture(app, "editor-narrow")
        XCTAssertFalse(app.descendants(matching: .any)["editor.inspector"].exists, "the inspector column is gone")
        app.buttons["editor.speakers"].click()
        XCTAssertTrue(app.textFields["editor.speakers.newName"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["Help"].click()
        app.menuBars.menuItems["Show Welcome Again"].click()
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForExistence(timeout: 5))
        for step in 1...5 {
            capture(app, "onboarding-step-\(step)", window: app.windows["onboarding"])
            let next = app.buttons[step == 5 ? "onboarding.finish" : "onboarding.continue"]
            XCTAssertTrue(next.exists)
            next.click()
        }
        XCTAssertFalse(app.buttons["onboarding.finish"].waitForExistence(timeout: 1))
    }

    func testCompactModelCatalogCanBeSearchedAndDismissed() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let models = app.buttons["settings.section.models"]
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        models.click()
        let browse = app.buttons["models.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        browse.click()
        let browser = app.sheets.firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        let search = browser.textFields["models.browse.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Whisper")
        XCTAssertTrue(browser.buttons["models.delete.whisperkit/small"].waitForExistence(timeout: 5))
        XCTAssertFalse(browser.buttons["models.download.apple/speech-analyzer"].exists)
        capture(app, "models-browser-whisper-light")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-such-language-model")
        XCTAssertTrue(browser.staticTexts["models.browse.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(browser.buttons["models.delete.whisperkit/small"].exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Apple")
        XCTAssertTrue(browser.staticTexts["models.systemTranslation.managed"].waitForExistence(timeout: 5))
        XCTAssertFalse(browser.buttons["models.download.apple/translation"].exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeText("OPUS")
        XCTAssertTrue(browser.popUpButtons["models.opus.source"].waitForExistence(timeout: 5))
        XCTAssertTrue(browser.popUpButtons["models.opus.target"].exists)
        let reverse = browser.descendants(matching: .any).matching(identifier: "models.opus.reverse").firstMatch
        capture(app, "models-opus-pair-light")
        XCTAssertTrue(reverse.exists, browser.debugDescription)
        XCTAssertTrue(browser.buttons["models.download.opus/en-de-ct2-int8"].exists)
        XCTAssertTrue(browser.buttons["models.download.opus/de-en-ct2-int8"].exists)
        reverse.click()
        XCTAssertFalse(browser.buttons["models.download.opus/de-en-ct2-int8"].exists)
        XCTAssertTrue(browser.buttons["models.opus.add"].isEnabled)
        browser.buttons["models.browse.done"].click()
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        capture(app, "models-compact-light")
    }

    func testModelFamiliesAreBrowsableForSpeechAndTranslation() throws { try modelFamilies(appearance: "light") }
    func testModelFamiliesAreBrowsableInDarkAppearance() throws { try modelFamilies(appearance: "dark") }

    /// The 1.1.0 families appear as grouped, searchable entries. Window captures feed the website.
    private func modelFamilies(appearance: String) throws {
        let app = launch(appearance: appearance)
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let models = app.buttons["settings.section.models"]
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        models.click()
        let browse = app.buttons["models.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        browse.click()
        let browser = app.sheets.firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        let search = browser.textFields["models.browse.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Parakeet")
        XCTAssertTrue(browser.buttons["models.download.fluidaudio/parakeet-ultra"].waitForExistence(timeout: 5))
        XCTAssertTrue(browser.buttons["models.download.fluidaudio/parakeet-eou-120m"].exists)
        capture(app, "models-parakeet-\(appearance)")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Gemma")
        XCTAssertTrue(browser.buttons["models.download.translategemma/4b-it-gguf-q4-k-m"].waitForExistence(timeout: 5))
        capture(app, "models-gemma-\(appearance)")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Nemotron")
        XCTAssertTrue(browser.buttons["models.download.native/nemotron-3.5-asr-q4"].waitForExistence(timeout: 5))
        capture(app, "models-nemotron-\(appearance)")
        browser.buttons["models.browse.done"].click()
    }

    func testReviewedHuggingFacePreviewDoesNotAcceptUnknownRevisions() throws {
        let app = launch(appearance: "light", width: 1100, height: 800)
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let models = app.buttons["settings.section.models"]
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        models.click()
        let intake = app.buttons["models.import.huggingface"]
        XCTAssertTrue(intake.waitForExistence(timeout: 5))
        intake.click()
        let browser = app.sheets.firstMatch
        let input = browser.textFields["models.huggingface.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("argmaxinc/whisperkit-coreml")
        browser.buttons["models.huggingface.review"].click()
        XCTAssertTrue(browser.buttons["models.delete.whisperkit/small"].waitForExistence(timeout: 5))
        XCTAssertTrue(browser.staticTexts["models.huggingface.source.whisperkit/small"].exists)
        capture(app, "models-reviewed-huggingface-light")
        input.click()
        input.typeKey("a", modifierFlags: .command)
        input.typeText("https://huggingface.co/argmaxinc/whisperkit-coreml/tree/dev")
        browser.buttons["models.huggingface.review"].click()
        XCTAssertTrue(browser.descendants(matching: .any)["models.huggingface.error"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(browser.buttons["models.delete.whisperkit/small"].exists)
        XCTAssertFalse(browser.buttons["models.download.whisperkit/large-v3-v20240930_626MB"].exists)
        browser.buttons["models.browse.done"].click()
        XCTAssertTrue(intake.waitForExistence(timeout: 5))
    }

    /// Website captures: General settings in each appearance (the site shows a light and a dark image).
    func testSettingsGeneralCapturesForBothAppearances() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            defer { app.terminate() }
            app.typeKey(",", modifierFlags: .command)
            XCTAssertTrue(app.buttons["settings.section.general"].waitForExistence(timeout: 5))
            let window = app.windows.containing(.button, identifier: "settings.section.general").firstMatch
            Thread.sleep(forTimeInterval: 0.8)
            capture(app, "settings-general-\(appearance)", window: window)
        }
    }

    private func openWeeklySync(_ app: XCUIApplication) {
        let recent = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "home.recent.", "Weekly sync")
        ).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.click()
        XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 10))
    }

    /// Regression: the last transcript lines were cut off even when the list was scrolled to its end (audio and video layouts).
    func testLastTranscriptLinesAreVisibleAtTheEnd() throws {
        for (appearance, video) in [("light", false), ("dark", true), ("light", true)] {
            let app = launch(
                appearance: appearance, arguments: ["-EarmarkTestLongTranscript", "YES"] + (video ? ["-EarmarkTestVideo", "YES"] : []))
            defer { app.terminate() }
            openWeeklySync(app)
            let window = app.windows.firstMatch
            Thread.sleep(forTimeInterval: video ? 2 : 0.5)
            // The transcript list is the scroll view that covers the lower middle of the window.
            // With a video the page has two columns (stage left, transcript right): probe the right column.
            let probe = CGPoint(x: window.frame.maxX - 160, y: window.frame.minY + window.frame.height * 0.7)
            let lists = app.scrollViews.allElementsBoundByIndex.filter { $0.frame.contains(probe) }
            let list = try XCTUnwrap(lists.min { $0.frame.height < $1.frame.height }, "transcript list not found")
            for _ in 0..<14 {
                list.scroll(byDeltaX: 0, deltaY: -4000)
                Thread.sleep(forTimeInterval: 0.2)
            }
            capture(app, "transcript-end-\(video ? "video" : "audio")-\(appearance)", window: window)
            // The final row starts at 7:24; its speaker and time block must end inside the list, not under its clipped edge.
            let last = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "7:24", "7:24")).firstMatch
            XCTAssertTrue(last.waitForExistence(timeout: 3), "the last transcript row must exist")
            // With the player bar under the list (no stage column) the last row must end above the bar; beside the stage column
            // the list runs to the bottom edge, so the row must end inside the list.
            let bar = app.buttons["editor.player.play"]
            XCTAssertTrue(bar.waitForExistence(timeout: 3))
            if bar.frame.minX > list.frame.minX && bar.frame.maxX < list.frame.maxX {
                XCTAssertLessThanOrEqual(last.frame.maxY, bar.frame.minY, "the last row (\(last.frame)) must end above the player bar (\(bar.frame))")
                XCTAssertLessThanOrEqual(list.frame.maxY, bar.frame.minY + 1, "the list (\(list.frame)) must not run under the player bar (\(bar.frame))")
            } else {
                XCTAssertLessThanOrEqual(last.frame.maxY, list.frame.maxY, "the last row (\(last.frame)) must end inside the list (\(list.frame))")
            }
        }
    }

    /// Every editor tool opens a popover that hangs off the control that asked for it, inside the window.
    func testEditorToolPopoversOpenNextToTheirButtons() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        openWeeklySync(app)
        let window = app.windows.firstMatch
        func check(_ trigger: XCUIElement, _ name: String, menuItem: String? = nil, from owner: XCUIElement? = nil) {
            let anchor = owner ?? trigger
            XCTAssertTrue(anchor.waitForExistence(timeout: 5), "\(name) button")
            trigger.click()
            if let menuItem { app.menuItems[menuItem].click() }
            let popover = app.popovers.firstMatch
            XCTAssertTrue(popover.waitForExistence(timeout: 5), "\(name) must open a popover")
            capture(app, "popover-\(name)", window: window)
            let button = anchor.frame, pop = popover.frame, win = window.frame
            // Toolbar popovers centre on their button, so one near the trailing edge may overhang the window by a few points
            // (at most 16, still on screen); vertically it must stay inside the window.
            XCTAssertTrue(
                win.insetBy(dx: -16, dy: -2).contains(pop), "\(name) popover \(pop) must stay inside the window \(win)")
            let horizontalGap = max(button.minX - pop.maxX, pop.minX - button.maxX, 0)
            let verticalGap = max(button.minY - pop.maxY, pop.minY - button.maxY, 0)
            XCTAssertLessThanOrEqual(horizontalGap, 8, "\(name) popover must overlap its button horizontally (\(pop) vs \(button))")
            XCTAssertLessThanOrEqual(verticalGap, 40, "\(name) popover must sit right by its button (\(pop) vs \(button))")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: popover)], timeout: 4)
                    == .completed, "\(name) must close on Escape")
        }
        check(app.buttons["editor.speakers"], "speakers")
        check(app.buttons["editor.translation"], "translate")
        let more = app.menuButtons["editor.more"]
        check(more, "retranscribe", menuItem: "Re-transcribe…")
        check(more, "bookmarks", menuItem: "Bookmarks and highlights")
        check(more, "options", menuItem: "View options")
    }

    func testSettingsSectionsRemainAvailable() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["settings.section.general"].waitForExistence(timeout: 5))
        app.buttons["settings.section.general"].click()
        let sections = [
            "general", "models", "intelligence", "languages", "audio", "meetings", "liveCaptions", "dictation", "transcriptAppearance",
            "ignoredSegments", "replacements", "translation", "exportDefaults", "storage", "keyboardShortcuts", "privacyPermissions",
        ]
        for (index, section) in sections.enumerated() {
            if index > 0 { app.typeKey(.downArrow, modifierFlags: []) }
            let target = app.buttons["settings.section.\(section)"]
            XCTAssertTrue(target.isSelected, "Arrow navigation must select \(section)")
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: target)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 3), .completed, "Selection must scroll \(section) into view")
            capture(app, "settings-\(section)", window: app.windows.containing(.button, identifier: "settings.section.general").firstMatch)
        }
    }

    /// The navigation pane is persistent: no sidebar toggle in the main window or in Settings, including after Settings is closed
    /// and opened again (SwiftUI rebuilds the window toolbar on reopen and used to bring the toggle back).
    func testNavigationPaneHasNoToggleInMainOrReopenedSettings() throws {
        let app = launch(appearance: "dark")
        defer { app.terminate() }
        Thread.sleep(forTimeInterval: 1.5)  // the toggle is hidden on the first window updates after launch
        capture(app, "main-window-nav-toggle-check")
        let toggleLabels = ["Toggle Sidebar", "Hide Sidebar", "Show Sidebar"]
        for label in toggleLabels {
            XCTAssertFalse(app.windows.firstMatch.buttons[label].exists, "Main window must not offer \(label)")
        }
        for pass in 1...2 {
            app.typeKey(",", modifierFlags: .command)
            XCTAssertTrue(app.buttons["settings.section.general"].waitForExistence(timeout: 5))
            let window = app.windows.containing(.button, identifier: "settings.section.general").firstMatch
            Thread.sleep(forTimeInterval: 0.8)
            for label in toggleLabels {
                XCTAssertFalse(window.buttons[label].exists, "Settings (open #\(pass)) must not offer \(label)")
            }
            capture(app, "settings-general-dark-open\(pass)", window: window)
            if pass == 1 {
                app.buttons["settings.section.models"].click()
                capture(app, "settings-models-dark", window: window)
            }
            app.typeKey("w", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Captures the hover highlight of representative toolbar buttons so its shape can be reviewed against the button.
    func testToolbarHoverStates() throws {
        let app = launch(appearance: "dark")
        defer { app.terminate() }
        func hover(_ element: XCUIElement, _ name: String) {
            guard element.waitForExistence(timeout: 5) else { return XCTFail("missing \(name)") }
            element.hover()
            Thread.sleep(forTimeInterval: 0.7)
            capture(app, "hover-\(name)")
        }
        hover(app.buttons["toolbar.transcribe"], "home-transcribe")
        app.typeKey("2", modifierFlags: .command)
        hover(app.buttons["queue.add"], "queue-add")
        app.typeKey("5", modifierFlags: .command)
        hover(app.descendants(matching: .any)["library.layout.grid"].firstMatch, "library-layout-grid")
        app.typeKey("4", modifierFlags: .command)
        hover(app.buttons["live.start"], "live-start")
    }

    /// The Zoom/Teams policy menus in the Meetings toolbar must change their label (and stored policy) when a choice is made.
    func testMeetingPolicyMenusChangeSelection() throws {
        let app = launch(appearance: "dark")
        defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        let zoom = app.descendants(matching: .any)["meetings.policy"].firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 8))
        capture(app, "meetings-policy-before")
        let before = zoom.value as? String ?? ""
        zoom.click()
        // Menu items carry no custom identifier; the first section is Zoom's.
        let auto = app.menuItems["Auto-transcribe + record"].firstMatch
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "policy choices must open")
        auto.click()
        Thread.sleep(forTimeInterval: 1)
        capture(app, "meetings-policy-after")
        let after = app.descendants(matching: .any)["meetings.policy"].firstMatch.value as? String ?? ""
        XCTAssertNotEqual(before, after, "label must reflect the new policy (was \(before), now \(after))")
    }

    /// Detect meetings: the live list shows every call that can be transcribed, each with its own actions.
    func testAvailableNowListsLiveCalls() throws {
        let app = launch(appearance: "dark", arguments: ["-EarmarkTestMeetingScan", "found"])
        defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["meetings.detect"].waitForExistence(timeout: 8))
        let zoom = app.buttons["meetings.available.zoom.transcribe"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 8), "a live Zoom call must be listed")
        XCTAssertTrue(app.buttons["meetings.available.meet.com.google.Chrome.transcribe"].exists, "a Meet call must be listed")
        XCTAssertTrue(app.buttons["meetings.available.browser.org.mozilla.firefox.record"].exists, "a plain browser call must be listed")
        capture(app, "meetings-available-now")
        app.buttons["meetings.detect"].click()
        XCTAssertTrue(zoom.waitForExistence(timeout: 5), "Detect keeps the list")
    }

    /// Detect meetings never fails silently: when nothing is running it says what it looked at.
    func testDetectMeetingsExplainsWhenNothingIsFound() throws {
        let app = launch(appearance: "light", arguments: ["-EarmarkTestMeetingScan", "none"])
        defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        let detect = app.buttons["meetings.detect"]
        XCTAssertTrue(detect.waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["meetings.available.nothing"].exists)
        detect.click()
        XCTAssertTrue(app.descendants(matching: .any)["meetings.available.nothing"].waitForExistence(timeout: 5))
        capture(app, "meetings-detect-nothing")
    }

    func testExpandedLightWorkspace() { expandedWorkspace(appearance: "light") }
    func testExpandedDarkWorkspace() { expandedWorkspace(appearance: "dark") }

    func testReducedMotionAndTransparency() {
        let app = launch(appearance: "dark", arguments: ["-EarmarkTestAccessibility", "reduced"])
        defer { app.terminate() }
        capture(app, "home-accessibility-reduced")
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["live.start"].waitForExistence(timeout: 5))
        capture(app, "live-accessibility-reduced")
        app.typeKey("1", modifierFlags: .command)
        openWeeklyTranscript(app)
        capture(app, "editor-accessibility-reduced")
    }

    private func expandedWorkspace(appearance: String) {
        let app = launch(appearance: appearance, width: 1720, height: 970)
        defer { app.terminate() }
        let window = app.windows["main"]
        let home = app.scrollViews["home.workbench"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(home.frame.width, window.frame.width - 340, "Home must use the available detail width")
        let searchButton = app.buttons["toolbar.quickOpen"]
        let transcribeButton = app.buttons["toolbar.transcribe"]
        XCTAssertGreaterThanOrEqual(searchButton.frame.height, 28)
        XCTAssertLessThanOrEqual(searchButton.frame.maxX, transcribeButton.frame.minX, "Search and Transcribe must not overlap")
        capture(app, "home-\(appearance)-expanded")
        app.typeKey("4", modifierFlags: .command)
        let source = app.descendants(matching: .any)["live.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let start = app.buttons["live.start"]
        XCTAssertTrue(start.exists)
        XCTAssertLessThanOrEqual(source.frame.maxX, start.frame.minX + 1, "Live source and Start must not overlap")
        XCTAssertTrue(window.frame.contains(source.frame) && window.frame.contains(start.frame))
        capture(app, "live-\(appearance)-expanded")
        app.typeKey("5", modifierFlags: .command)
        let librarySearch = app.searchFields.firstMatch
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toolbar.quickOpen"].exists, "Library has one search field")
        librarySearch.click()
        librarySearch.typeText("Weekly")
        capture(app, "library-\(appearance)-expanded")
        app.typeKey("6", modifierFlags: .command)
        let empty = app.descendants(matching: .any)["library.empty"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        capture(app, "recently-deleted-\(appearance)-expanded")
        assertEmptySheetFillsWorkspace(app: app, window: window, dark: appearance == "dark")
        let toolbar = window.toolbars.firstMatch
        let brand = window.descendants(matching: .any)["sidebar.brand"].firstMatch
        let retention = window.staticTexts["library.retention"]
        XCTAssertTrue(brand.exists && retention.exists)
        XCTAssertGreaterThanOrEqual(brand.frame.minY, toolbar.frame.maxY - 1, "Brand must sit below the titlebar")
        XCTAssertGreaterThanOrEqual(retention.frame.minY, toolbar.frame.maxY - 1, "Retention copy must sit below the titlebar")
    }

    func testQueueStatesAndClearing() {
        let app = launch(appearance: "dark", arguments: ["-EarmarkTestQueue", "YES"])
        defer { app.terminate() }
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Paused notes.wav"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.progressIndicators.count, 2, "Only running and paused rows show determinate progress")
        capture(app, "queue-all-states-dark")
        app.buttons["queue.clearFinished"].click()
        let finished = app.staticTexts["Finished conversation.wav"]
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: finished)], timeout: 5),
            .completed)
        XCTAssertTrue(app.staticTexts["Paused notes.wav"].exists)
        XCTAssertTrue(app.staticTexts["Failed import.wav"].exists)
        app.menuButtons["queue.actions"].click()
        app.menuItems["Clear Queue…"].click()
        app.buttons["Cancel active work and clear queue"].click()
        XCTAssertTrue(app.staticTexts["Queue is empty"].waitForExistence(timeout: 5))
        app.typeKey("5", modifierFlags: .command)
        let preserved = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Weekly sync", "Weekly sync")
        ).firstMatch
        XCTAssertTrue(preserved.waitForExistence(timeout: 5), "Clearing queue history must preserve transcripts")
    }

    func testPlaybackShortcutsInDockedAndDetachedPlayers() {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        openWeeklyTranscript(app)
        let play = app.buttons["editor.player.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(play.isEnabled, "The fixture must use the real media player")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(play.value as? String, "Playing")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(play.value as? String, "Paused")
        let position = app.staticTexts["editor.player.position"]
        let before = Double(position.value as? String ?? "") ?? 0
        app.typeKey(.rightArrow, modifierFlags: [])
        let forward = Double(position.value as? String ?? "") ?? 0
        XCTAssertEqual(forward - before, 5, accuracy: 0.25)
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertEqual(Double(position.value as? String ?? "") ?? 0, before, accuracy: 0.25)
        // The waveform scrubber: click seeks, VoiceOver gets a spoken value, View > Zoom In zooms it and Fit resets.
        let seek = app.descendants(matching: .any)["editor.player.seek"].firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 5))
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)).click()
        let scrubbed = Double(position.value as? String ?? "") ?? 0
        XCTAssertTrue((30...55).contains(scrubbed), "Clicking 60 % across a 72 s file seeks near 43 s, got \(scrubbed)")
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuBarItems["View"].menuItems["Zoom In"].click()
        let fit = app.buttons["editor.player.seek.fit"]
        XCTAssertTrue(fit.waitForExistence(timeout: 3), "Zooming in shows the Fit button")
        capture(app, "editor-player-dock-zoomed-light")
        fit.click()
        XCTAssertFalse(fit.waitForExistence(timeout: 1))
        capture(app, "editor-player-dock-light")
        app.menuButtons["editor.player.options"].click()
        app.menuItems["Detach player"].click()
        let detached = app.descendants(matching: .any)["editor.detachedPlayer"].firstMatch
        XCTAssertTrue(detached.waitForExistence(timeout: 5))
        let detachedWindow = app.windows.containing(.any, identifier: "editor.detachedPlayer").firstMatch
        detachedWindow.click()
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(detachedWindow.buttons["editor.player.play"].value as? String, "Playing")
        app.typeKey(.space, modifierFlags: [])
        capture(app, "detached-player-light", window: detachedWindow)
    }

    private func openWeeklyTranscript(_ app: XCUIApplication) {
        let recent = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "home.recent.", "Weekly sync")
        ).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.click()
        XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 10))
    }

    func testWelcomeOnlyInHelpAndSettingsAndMenuBarControls() {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        app.menuBars.menuBarItems["Window"].click()
        XCTAssertFalse(app.menuItems["Welcome to Earmark"].exists)
        app.typeKey(.escape, modifierFlags: [])
        let status = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.click()
        XCTAssertTrue(app.buttons["menuBar.transcribe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["menuBar.open"].exists)
        XCTAssertTrue(app.buttons["menuBar.detectMeetings"].exists)
        let panel = app.descendants(matching: .any)["menuBar.panel"].firstMatch
        XCTAssertTrue(panel.exists)
        if panel.frame.minY >= 0 {
            capture(app, "menu-bar-light", window: panel)
        } else {
            let note = XCTAttachment(
                string:
                    "XCTest cannot crop this secondary-monitor popup. Its controls are tested here; inspect it with native computer-use QA."
            )
            note.lifetime = .keepAlways
            add(note)
        }
        app.buttons["menuBar.open"].click()
        XCTAssertTrue(app.buttons["sidebar.home"].exists)
    }

    private func assertSidebarLabelsDrawn(_ app: XCUIApplication, dark: Bool) {
        let window = app.windows["main"]
        guard let bitmap = NSBitmapImageRep(data: window.screenshot().pngRepresentation) else { return XCTFail("Screenshot missing") }
        let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
        for section in ["home", "queue", "meetings", "live", "library", "recentlyDeleted"] {
            let row = app.buttons["sidebar.\(section)"].frame
            let left = Int((row.minX - window.frame.minX + 38) * scale)
            let right = Int((row.maxX - window.frame.minX - 12) * scale)
            let top = Int((row.midY - window.frame.minY - 6) * scale)
            let bottom = Int((row.midY - window.frame.minY + 6) * scale)
            var inkPixels = 0
            for y in stride(from: max(0, top), to: min(bitmap.pixelsHigh, bottom), by: 2) {
                for x in stride(from: max(0, left), to: min(bitmap.pixelsWide, right), by: 2) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let lightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    if dark ? lightness > 0.5 : lightness < 0.45 { inkPixels += 1 }
                }
            }
            XCTAssertGreaterThan(inkPixels, 8, "Sidebar label must remain painted after route changes: \(section)")
        }
    }

    private func assertEmptySheetFillsWorkspace(app: XCUIApplication, window: XCUIElement, dark: Bool) {
        // AX groups report their children's union, not the painted frame. Check the actual edges of the rendered sheet.
        let screenshot = window.screenshot()
        guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else { return XCTFail("Window screenshot missing") }
        let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
        let split = app.splitters.firstMatch
        let detailStart = split.exists ? split.frame.maxX - window.frame.minX : 232
        var colors: [NSColor] = []
        for pointX in [detailStart + 28, window.frame.width - 28] {
            guard let color = bitmap.colorAt(x: Int(pointX * scale), y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else {
                return XCTFail("Sheet pixel missing")
            }
            colors.append(color)
            XCTAssertGreaterThan(color.redComponent, dark ? 0.07 : 0.9, "No unpainted black bars at the workspace edges")
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
        }
        // Display profiles may transform absolute RGB values; the two edges must still be the same solid surface.
        XCTAssertEqual(colors[0].redComponent, colors[1].redComponent, accuracy: 0.02)
        XCTAssertEqual(colors[0].greenComponent, colors[1].greenComponent, accuracy: 0.02)
        XCTAssertEqual(colors[0].blueComponent, colors[1].blueComponent, accuracy: 0.02)
    }

    // MARK: Workspace (1.2.0)

    /// Library, then the pinned folder, then Recently Deleted, then the compact model line, then Settings: top to bottom.
    func testSidebarListsPinnedFoldersUnderLibraryAndTheyOpenTheFolder() throws {
        let app = launch(appearance: "light", arguments: ["-EarmarkTestFolders", "YES"])
        defer { app.terminate() }
        let library = app.buttons["sidebar.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        let pinned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.pinned.folder-")).firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 8), "a pinned folder must be listed in the sidebar")
        let trash = app.buttons["sidebar.recentlyDeleted"]
        XCTAssertLessThan(library.frame.minY, pinned.frame.minY)
        XCTAssertLessThan(pinned.frame.minY, trash.frame.minY)
        XCTAssertLessThan(trash.frame.minY, app.buttons["sidebar.settings"].frame.minY)
        let modelChip = app.buttons["sidebar.modelChip"]
        if modelChip.exists {
            XCTAssertLessThan(trash.frame.minY, modelChip.frame.minY)
            XCTAssertLessThan(modelChip.frame.height, 60, "the model picker is one compact line")
        }
        capture(app, "sidebar-pinned")
        pinned.click()
        XCTAssertTrue(app.descendants(matching: .any)["library.breadcrumb"].waitForExistence(timeout: 5), "opening a pinned folder shows it in the Library")
    }

    /// One click opens a transcript, in the list and in the grid.
    func testLibraryItemsOpenWithASingleClickInListAndGrid() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        app.buttons["sidebar.library"].click()
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.item."))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 8))
        items.firstMatch.click()
        XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 8), "a single click in the list opens the transcript")
        app.buttons["toolbar.back"].click()
        app.buttons["library.layout.grid"].click()
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 8))
        items.firstMatch.click()
        XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 8), "a single click in the grid opens the transcript")
    }

    /// Select mode: checkmarks appear, a selection reveals Delete, Delete offers Undo. Same in list and grid.
    func testSelectModeShowsActionsAndDeleteCanBeUndone() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        app.buttons["sidebar.library"].click()
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.item."))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["library.delete"].exists, "no Delete button outside Select mode")
        for grid in [false, true] {
            if grid { app.buttons["library.layout.grid"].click() }
            let before = items.count
            let select = app.buttons["library.select"]
            XCTAssertTrue(select.waitForExistence(timeout: 5))
            select.click()
            XCTAssertTrue(app.staticTexts["library.selectionCount"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["library.delete"].exists, "Delete appears once something is selected")
            items.firstMatch.click()
            XCTAssertTrue(app.buttons["library.delete"].waitForExistence(timeout: 5), "selecting an item reveals Delete")
            XCTAssertFalse(app.buttons["editor.export"].exists, "a click in Select mode does not open the transcript")
            capture(app, "library-select-\(grid ? "grid" : "list")")
            app.buttons["library.delete"].click()
            XCTAssertTrue(app.buttons["library.undoDelete"].waitForExistence(timeout: 5), "Delete offers Undo")
            XCTAssertEqual(items.count, before - 1)
            app.buttons["library.undoDelete"].click()
            let restored = NSPredicate(format: "count == %d", before)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: items)], timeout: 6), .completed, "Undo brings the item back")
            app.buttons["library.select"].click()  // Done
        }
    }

    /// Grouping works in the grid: headers by date, collapsible.
    func testGridGroupsByDateAndGroupsCollapse() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        app.buttons["sidebar.library"].click()
        app.buttons["library.layout.grid"].click()
        let group = app.menuButtons["library.group"]
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        group.click()
        app.menuItems["Date"].click()
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.group.date.")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the grid shows date group headers")
        capture(app, "library-grid-grouped-by-date")
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.item."))
        let before = items.count
        header.click()
        let collapsed = NSPredicate { _, _ in items.count < before }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: collapsed, object: nil)], timeout: 5), .completed, "a header collapses its group")
    }

    func testLibraryShowsFolderCardsAndGroupsByType() throws {
        let app = launch(appearance: "dark", arguments: ["-EarmarkTestFolders", "YES"])
        defer { app.terminate() }
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["library.folders"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.folder.")).firstMatch.exists)
        let group = app.menuButtons["library.group"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.click()
        app.menuItems["Type"].click()
        XCTAssertTrue(app.buttons["library.group.type.meeting"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["library.group.type.file"].exists)
        capture(app, "library-grouped-by-type")
        app.buttons["library.group.type.file"].click()  // collapse
        XCTAssertTrue(app.buttons["library.group.type.file"].exists)
    }

    func testTranscriptPageHasTabsAndNotesCanBeSummarisedAndUndone() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        openWeeklySync(app)
        let tabs = app.descendants(matching: .any)["workspace.tabBar"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        for name in ["Transcript", "Notes", "Chat", "Files"] { XCTAssertTrue(app.buttons[name].exists, "\(name) tab") }
        app.buttons["Notes"].click()
        let editor = app.textViews["notes.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("Ask Elena about staging")
        app.buttons["notes.summarize"].click()
        XCTAssertTrue(app.descendants(matching: .any)["summarize.sheet"].waitForExistence(timeout: 5))
        capture(app, "summarize-sheet")
        app.buttons["summarize.run"].click()
        XCTAssertTrue(app.descendants(matching: .any)["notes.summaryNotice"].waitForExistence(timeout: 8))
        XCTAssertTrue((editor.value as? String)?.contains("## Summary") == true, "the page is replaced by the summary")
        XCTAssertTrue((editor.value as? String)?.contains("Ask Elena about staging") == true, "the user's notes are part of the summary")
        capture(app, "notes-summary")
        app.buttons["notes.undoSummary"].click()
        XCTAssertEqual((editor.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "Ask Elena about staging")
    }

    func testChatAnswersWithSourcesAndTheSourceJumpsBack() throws {
        let app = launch(appearance: "dark")
        defer { app.terminate() }
        openWeeklySync(app)
        app.buttons["Chat"].click()
        let suggestion = app.buttons.matching(identifier: "chat.suggestion").firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        suggestion.click()
        XCTAssertTrue(app.descendants(matching: .any)["chat.message.assistant"].waitForExistence(timeout: 8))
        let source = app.buttons.matching(identifier: "chat.source").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5), "an answer shows where it came from")
        capture(app, "chat-answer")
        source.click()
        XCTAssertTrue(app.buttons["Transcript"].waitForExistence(timeout: 5))
    }

    /// Notes are Markdown with a live preview: typing builds the note, Return continues lists, and the saved text stays the Markdown.
    func testNotesTypedAsMarkdownKeepTheTextAndContinueLists() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        openWeeklySync(app)
        app.buttons["Notes"].click()
        let editor = app.textViews["notes.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("# Plan\nWe **agreed** to ship *Friday*, see `build 4` and [the doc](https://example.com).\n- first\nsecond\n\n\n1. one\ntwo\n\n\n- [ ] send notes\n\n\n> a quote\n")
        let expected = "# Plan\nWe **agreed** to ship *Friday*, see `build 4` and [the doc](https://example.com).\n- first\n- second\n\n1. one\n2. two\n\n- [ ] send notes\n\n> a quote\n"
        XCTAssertEqual(editor.value as? String, expected, "Return continues bullets and numbers, and ends the list on an empty item")
        capture(app, "notes-markdown")
    }

    func testSlidesCanBeViewedInsteadOfTheVideoAndPaged() throws {
        let app = launch(appearance: "light", arguments: ["-EarmarkTestSlides", "YES"])
        defer { app.terminate() }
        openWeeklySync(app)
        app.buttons["Slides"].click()  // the stage switch
        let position = app.staticTexts["slides.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 8))
        XCTAssertEqual(position.value as? String, "Slide 1 of 3")
        app.buttons["slides.next"].click()
        XCTAssertEqual(position.value as? String, "Slide 2 of 3")
        capture(app, "slides-stage")
        app.buttons["slides.thumb.2"].click()
        XCTAssertEqual(position.value as? String, "Slide 3 of 3")
        app.buttons["Files · 1"].click()
        XCTAssertTrue(app.descendants(matching: .any)["files.page"].waitForExistence(timeout: 5))
    }

    func testWhenAppleIntelligenceIsOffSummariseAndChatExplainWhy() throws {
        let app = launch(appearance: "light", arguments: ["-EarmarkTestIntelligence", "off"])
        defer { app.terminate() }
        openWeeklySync(app)
        XCTAssertFalse(app.buttons["editor.summarize"].isEnabled)
        app.buttons["Chat"].click()
        XCTAssertTrue(app.descendants(matching: .any)["chat.unavailable"].waitForExistence(timeout: 5))
        capture(app, "chat-unavailable")
        app.buttons["Notes"].click()
        let editor = app.textViews["notes.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "notes work without Apple Intelligence")
    }

    func testIntelligenceSettingsPaneShowsStatusAndOptions() throws {
        let app = launch(appearance: "dark")
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let section = app.buttons["settings.section.intelligence"]
        XCTAssertTrue(section.waitForExistence(timeout: 8))
        section.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.intelligence.status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["settings.intelligence.auto"].exists || app.switches["settings.intelligence.auto"].exists)
        capture(app, "settings-intelligence")
    }
}
