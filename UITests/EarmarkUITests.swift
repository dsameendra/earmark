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
        capture(app, "editor-narrow-before-inspector")
        let inspector = app.descendants(matching: .any)["toolbar.inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        inspector.click()
        XCTAssertTrue(app.descendants(matching: .any)["editor.inspector"].waitForExistence(timeout: 5))
        capture(app, "editor-narrow-inspector")
        app.buttons["Edit speakers…"].click()
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
            let probe = CGPoint(x: window.frame.midX - 100, y: window.frame.minY + window.frame.height * 0.85)
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
            // The list's own frame can extend under the player bar, so measure against the bar's top instead.
            let bar = app.buttons["editor.player.play"]
            XCTAssertTrue(bar.waitForExistence(timeout: 3))
            XCTAssertLessThanOrEqual(last.frame.maxY, bar.frame.minY, "the last row (\(last.frame)) must end above the player bar (\(bar.frame))")
            XCTAssertLessThanOrEqual(list.frame.maxY, bar.frame.minY + 1, "the list (\(list.frame)) must not run under the player bar (\(bar.frame))")
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
        check(app.buttons["editor.retranscribe"], "retranscribe")
        let more = app.menuButtons["editor.more"]
        check(more, "bookmarks", menuItem: "Bookmarks and highlights")
        check(more, "options", menuItem: "View options")
        let inspector = app.descendants(matching: .any)["editor.inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        check(app.buttons["Edit speakers…"], "inspector-speakers")
        check(app.buttons["Add an earmark…"], "inspector-earmark")
    }

    func testSettingsSectionsRemainAvailable() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["settings.section.general"].waitForExistence(timeout: 5))
        app.buttons["settings.section.general"].click()
        let sections = [
            "general", "models", "languages", "audio", "meetings", "liveCaptions", "dictation", "transcriptAppearance",
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
        let zoom = app.descendants(matching: .any)["meetings.policy.zoom"].firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 8))
        capture(app, "meetings-policy-before")
        let before = zoom.value as? String ?? ""
        zoom.click()
        let auto = app.descendants(matching: .any)["meetings.policy.zoom.autoTranscribeAndRecord"].firstMatch
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "policy choices must open")
        auto.click()
        Thread.sleep(forTimeInterval: 1)
        capture(app, "meetings-policy-after")
        let after = app.descendants(matching: .any)["meetings.policy.zoom"].firstMatch.value as? String ?? ""
        XCTAssertNotEqual(before, after, "label must reflect the new policy (was \(before), now \(after))")
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
}
