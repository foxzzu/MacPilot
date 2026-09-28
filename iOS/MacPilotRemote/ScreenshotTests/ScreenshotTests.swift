import XCTest

/// Captures App Store screenshots by driving the real app in the simulator.
/// Tab selection uses indexes (home=0, devices=1, settings=2) so the test is
/// independent of the device language.
final class ScreenshotTests: XCTestCase {

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(
            uniformTypeIdentifier: "public.png",
            name: "\(name).png",
            payload: shot.pngRepresentation,
            userInfo: nil
        )
        att.lifetime = .keepAlways
        add(att)
    }

    private func launchAndSettle() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        sleep(6) // let Bonjour discovery settle so the found-Mac state renders
        return app
    }

    @MainActor
    func testScreenshotHome() {
        let app = launchAndSettle()
        capture("01-home")
        _ = app // silence unused warning when queries are adjusted per screen
    }

    @MainActor
    func testScreenshotDevices() {
        let app = launchAndSettle()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(3)
        capture("02-devices")
    }

    @MainActor
    func testScreenshotPairingSheet() {
        let app = launchAndSettle()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons.element(boundBy: 1).tap()
        sleep(2)
        // The discovered row's pair button: 配对 (zh-Hans) / Pair (en).
        let pairZH = app.buttons["配对"].firstMatch
        let pairEN = app.buttons["Pair"].firstMatch
        let pair = pairZH.exists ? pairZH : pairEN
        guard pair.exists else {
            XCTFail("pair button not found; discovered list may be empty")
            return
        }
        pair.tap()
        sleep(3) // let the waiting state render
        capture("03-pairing")
        let cancelZH = app.buttons["取消"].firstMatch
        let cancelEN = app.buttons["Cancel"].firstMatch
        (cancelZH.exists ? cancelZH : cancelEN).tap()
    }

    @MainActor
    func testScreenshotSettings() {
        let app = launchAndSettle()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        tabBar.buttons.element(boundBy: 2).tap()
        sleep(3)
        capture("04-settings")
    }

    @MainActor
    func testConnectionPriorityCanBeReorderedAndPersists() {
        let app = launchAndSettle()
        app.tabBars.buttons.element(boundBy: 2).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        let bluetooth = app.staticTexts["connectionPriority.bluetooth"]
        let lan = app.staticTexts["connectionPriority.localNetwork"]
        XCTAssertTrue(bluetooth.waitForExistence(timeout: 5))
        XCTAssertTrue(lan.exists)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = app.frame.width * 0.9
        origin.withOffset(CGVector(dx: x, dy: bluetooth.frame.midY))
            .press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: x, dy: lan.frame.minY)))
        XCTAssertLessThan(bluetooth.frame.midY, lan.frame.midY)
        capture("05-connection-priority")
        app.terminate()
        app.launch()
        app.tabBars.buttons.element(boundBy: 2).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        XCTAssertLessThan(bluetooth.frame.midY, lan.frame.midY)
        // Restore the default order for subsequent screenshot runs.
        let awdl = app.staticTexts["connectionPriority.awdl"]
        origin.withOffset(CGVector(dx: x, dy: bluetooth.frame.midY))
            .press(forDuration: 0.8, thenDragTo: origin.withOffset(CGVector(dx: x, dy: awdl.frame.maxY + 10)))
        XCTAssertGreaterThan(bluetooth.frame.midY, awdl.frame.midY)
    }
}
