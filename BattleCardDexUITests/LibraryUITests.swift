import XCTest

final class LibraryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(outcome: String = "match", appearance: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BATTLE_CARD_DEX_USE_PREVIEW"] = "1"
        app.launchEnvironment["BATTLE_CARD_DEX_SCAN_OUTCOME"] = outcome
        if let appearance { app.launchArguments = ["-appearance", appearance] }
        app.launch()
        let tab = app.buttons["home-tab-library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
        return app
    }
    private func scan(_ app: XCUIApplication) {
        app.buttons["library-scan-cards"].firstMatch.tap()
        let shutter = app.buttons["card-scanner-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5)); shutter.tap()
    }
    func testManualAddAndDuplicateQuantity() {
        let app = launch(); scan(app)
        let add = app.buttons["scanner-add-to-library"]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        XCTAssertTrue(app.buttons["Scan Another"].waitForExistence(timeout: 5))
        app.buttons["Scan Another"].tap(); app.buttons["card-scanner-shutter"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap(); app.buttons["Done"].tap()
        let card = app.buttons["library-card-preview-card-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 5)); XCTAssertTrue(card.label.contains("2 copies"))
        card.tap()
        let close = app.buttons["Close card viewer"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        if app.frame.height > app.frame.width {
            let surface = app.descendants(matching: .any)["interactive-card-surface"].firstMatch
            XCTAssertGreaterThan(surface.frame.width, app.frame.width * 0.7)
        }
        close.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }
    func testAutoAddSavesFollowingScan() {
        let app = launch(); scan(app)
        XCTAssertTrue(app.buttons["scanner-add-to-library"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["scanner-auto-add"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Scan Another"].waitForExistence(timeout: 5))
        app.buttons["Scan Another"].tap(); app.buttons["card-scanner-shutter"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5)); app.buttons["Done"].tap()
        let tile = app.buttons["library-card-preview-card-1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5)); XCTAssertTrue(tile.label.contains("2 copies"))
    }
    func testOpenedPackKeepsTenCardsBeforeEveryReveal() {
        let app = launch(); app.buttons["home-tab-packs"].tap(); app.buttons["pack-me5"].tap()
        let cut = app.descendants(matching: .any)["pack-cut-control"].firstMatch
        XCTAssertTrue(cut.waitForExistence(timeout: 8))
        let start = cut.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        let end = cut.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["CARD 1 OF 10"].waitForExistence(timeout: 5))
        app.buttons["Close pack"].tap(); app.buttons["home-tab-library"].tap()
        app.buttons["library-source-pulls"].tap()
        XCTAssertTrue(app.staticTexts["10 cards"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Pack pulls saved before reveal"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testLibraryHeaderAppearsAboveMainTabs() {
        let app = launch()
        let tabs = app.buttons["home-tab-library"]
        let scan = app.buttons["library-scan-cards"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        XCTAssertLessThan(app.staticTexts["Your Library"].frame.maxY, tabs.frame.minY)
        XCTAssertGreaterThanOrEqual(app.staticTexts["Collected by you"].frame.minY, app.staticTexts["Your Library"].frame.maxY)
        XCTAssertLessThan(scan.frame.maxY, tabs.frame.minY)
        app.buttons["home-tab-packs"].tap()
        XCTAssertFalse(scan.exists)
        app.buttons["home-tab-pokemon"].tap()
        XCTAssertFalse(scan.exists)
    }
    func testPortraitFailureStaysOnScreenAfterLargeCapture() {
        let app = launch(outcome: "missing")
        XCUIDevice.shared.orientation = .portrait
        scan(app)
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(retry.isHittable)
        XCTAssertGreaterThanOrEqual(retry.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(retry.frame.maxY, app.frame.maxY)
        let message = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No matching card found.")).firstMatch
        XCTAssertTrue(message.exists)
        XCTAssertLessThanOrEqual(message.frame.maxY, app.frame.maxY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Portrait failure after captured photo"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testSavedActionsInLightAndDarkModes() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance); scan(app)
            let addCard = app.buttons["scanner-add-to-library"]
            XCTAssertTrue(addCard.waitForExistence(timeout: 5)); addCard.tap()
            let another = app.buttons["Scan Another"]
            XCTAssertTrue(another.waitForExistence(timeout: 5)); XCTAssertTrue(another.isHittable)
            XCTAssertLessThanOrEqual(another.frame.maxY, app.frame.maxY)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Saved scanner actions - \(appearance)"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.buttons["Done"].tap(); app.terminate()
        }
    }
    func testMultipleMatchesRequireSelection() {
        let app = launch(outcome: "multiple"); scan(app)
        XCTAssertTrue(app.staticTexts["Choose the matching artwork"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scanner-add-to-library"].exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose Creature 1 Card")).firstMatch.tap()
        XCTAssertTrue(app.buttons["scanner-add-to-library"].waitForExistence(timeout: 5))
    }
    func testNoMatchAndRecognitionFailureOfferRetry() {
        for outcome in ["missing", "error"] {
            let app = launch(outcome: outcome); scan(app)
            let retry = app.buttons["Try Again"]
            XCTAssertTrue(retry.waitForExistence(timeout: 5)); retry.tap()
            XCTAssertTrue(app.buttons["card-scanner-shutter"].waitForExistence(timeout: 5))
            app.buttons["library-scanner-close"].tap(); app.terminate()
        }
    }
    func testLibraryAdaptsToLandscapeAndSourceSelection() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["library-source-pulls"].tap()
        let sourceSelection = XCTAttachment(screenshot: app.screenshot())
        sourceSelection.name = "Landscape library source selection"
        sourceSelection.lifetime = .keepAlways
        add(sourceSelection)
        XCTAssertTrue(app.buttons["Explore Packs"].waitForExistence(timeout: 3))
        app.buttons["Explore Packs"].tap()
        XCTAssertTrue(app.buttons["pack-me5"].waitForExistence(timeout: 3))
        app.buttons["home-tab-library"].tap()
        app.buttons["library-scan-cards"].firstMatch.tap()
        XCTAssertTrue(app.buttons["card-scanner-shutter"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Library scanner landscape"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCUIDevice.shared.orientation = .portrait
    }
}
