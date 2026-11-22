import XCTest

/// Deterministic mock-service flows. Never requests TCC permissions or downloads real models.
@MainActor
final class EarmarkUITests: XCTestCase {

    private func launch(appearance: String, width: Int = 1440, height: Int = 900) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-UseMocks", "-ApplePersistenceIgnoreState", "YES", "-EarmarkTestAppearance", appearance,
            "-EarmarkTestWidth", String(width), "-EarmarkTestHeight", String(height),
        ]
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
        let attachment = XCTAttachment(screenshot: (window ?? app.windows.firstMatch).screenshot())
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
        }
        app.typeKey("1", modifierFlags: .command)
        let recent = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "home.recent.", "Weekly sync")
        ).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.click()
        XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 10))
        capture(app, "editor-\(appearance)-1440x900")
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
        app.typeKey(.escape, modifierFlags: [])
    }

    func testNarrowInspectorAndAllOnboardingSteps() throws {
        let app = launch(appearance: "light", width: 960, height: 600)
        defer { app.terminate() }
        let recent = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "home.recent.", "Weekly sync")
        ).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.click()
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
            capture(app, "onboarding-step-\(step)", window: app.windows["Welcome to Earmark"])
            let next = app.buttons[step == 5 ? "onboarding.finish" : "onboarding.continue"]
            XCTAssertTrue(next.exists)
            next.click()
        }
        XCTAssertFalse(app.buttons["onboarding.finish"].waitForExistence(timeout: 1))
    }

    func testSettingsSectionsRemainAvailable() throws {
        let app = launch(appearance: "light")
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["settings.section.general"].waitForExistence(timeout: 5))
        for section in ["general", "audio", "models", "languages", "meetings", "exportDefaults", "privacyPermissions"] {
            app.buttons["settings.section.\(section)"].click()
            capture(app, "settings-\(section)", window: app.windows["Earmark Settings"])
        }
        app.menuButtons["More settings"].click()
        for title in [
            "Live Captions", "Dictation", "Transcript Appearance", "Ignored Segments", "Replacements", "Translation", "Storage",
            "Keyboard Shortcuts",
        ] {
            XCTAssertTrue(app.menuItems[title].exists, "Settings section missing: \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }
}
