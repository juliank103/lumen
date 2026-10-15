import XCTest

/// Screenshots every screen of the app with the invented preview data (user, Oct 15: "a screenshot of EVERY screen,
/// including stuff you have to scroll down to see"). Runs in the cloud build; screenshots are exported from the test
/// results as the `screen-tour` artifact, numbered in tour order. Steps that can't find their button are skipped so
/// one missing element doesn't end the tour.
final class ScreenTour: XCTestCase {
    private var app: XCUIApplication!
    private var count = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-lumenPreview", "-dark"]
        app.launch()
        sleep(3)
    }

    // MARK: Helpers

    private func shot(_ name: String) {
        count += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = String(format: "%03d-%@", count, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The screen, then one screenshot per page while scrolling down; back to the top afterwards.
    private func shotScrolling(_ name: String, pages: Int) {
        shot(name)
        guard pages > 1 else { return }
        for page in 2...pages {
            app.swipeUp(velocity: .slow)
            sleep(1)
            shot("\(name)-p\(page)")
        }
        for _ in 0..<pages { app.swipeDown(velocity: .fast) }
        sleep(1)
    }

    /// Taps only what can be tapped: a failed tap ends a UI test, so anything hidden or covered is skipped.
    @discardableResult
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
        sleep(1)
        return true
    }

    private func text(_ contains: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
    }

    private func button(_ contains: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
    }

    private func go(_ section: String) {
        tap(app.buttons["Menu"].firstMatch)
        tap(app.buttons["menu." + section].firstMatch)
        sleep(1)
    }

    private func back() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists && backButton.isHittable { backButton.tap(); sleep(1) }
    }

    /// Closes a menu or the side menu by tapping the empty strip at the right edge (outside the cards' padding).
    private func dismissPopup() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.55)).tap()
        sleep(1)
    }

    private func cancel() {
        if !tap(app.alerts.buttons["Cancel"].firstMatch, timeout: 1),
           !tap(app.buttons["Cancel"].firstMatch, timeout: 1),
           !tap(app.buttons["Done"].firstMatch, timeout: 1) {
            app.swipeDown(velocity: .fast)
            sleep(1)
        }
    }

    // MARK: The tour

    func testEveryScreen() {
        // Home
        shotScrolling("home", pages: 3)
        if tap(app.buttons["Order options"].firstMatch) { shot("home-order-options"); dismissPopup() }
        if tap(button("Other next steps")) { shot("home-other-next-steps"); dismissPopup() }
        if tap(app.buttons["menu.home"].firstMatch, timeout: 1) == false {
            tap(app.buttons["Menu"].firstMatch); shot("menu-open"); dismissPopup()
        }
        tap(app.buttons["Menu"].firstMatch)
        if tap(app.buttons["menu.help"].firstMatch) { shot("help"); cancel() }

        // Offers
        go("offers")
        for filter in ["Taken", "Completed", "Ended early", "All"] {
            if tap(app.buttons[filter].firstMatch) { shotScrolling("offers-\(filter.lowercased().replacingOccurrences(of: " ", with: "-"))", pages: 2) }
        }
        if tap(text("Olive Garden")) {
            shotScrolling("offer-detail-taken", pages: 3)
            if tap(text("How Lumen decided")) { shotScrolling("offer-how-lumen-decided", pages: 2); back() }
            back()
        }
        if tap(text("Roadtrip Bowls")) {
            shotScrolling("offer-detail-not-taken", pages: 2)
            back()
        }

        // Earnings (week)
        go("earnings")
        shotScrolling("earnings-week", pages: 7)
        for tile in ["Hours online", "Miles", "Orders", "Deadhead", "Store wait"] {
            if tap(button(tile)) { shot("earnings-chart-\(tile.lowercased().replacingOccurrences(of: " ", with: "-"))") }
        }
        tap(button("Earnings"))
        app.swipeUp(velocity: .slow); app.swipeUp(velocity: .slow); sleep(1)
        for lens in ["App", "Area", "Store", "Period"] {
            if tap(app.buttons[lens].firstMatch) { shot("earnings-breakdown-\(lens.lowercased())") }
        }
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        let today = Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        if tap(text(today)) { shotScrolling("earnings-day-detail", pages: 3); back() }
        if tap(app.buttons["Choose a week"].firstMatch) { shot("earnings-choose-week"); cancel() }
        if tap(app.buttons["More options"].firstMatch) {
            shot("earnings-more-menu")
            if tap(button("Fix the start time")) { shot("earnings-fix-start-time"); cancel() } else { dismissPopup() }
        }
        if tap(app.buttons["More options"].firstMatch) {
            if tap(button("Add a past shift")) { shot("earnings-add-past-shift"); cancel() } else { dismissPopup() }
        }
        if tap(app.buttons["More options"].firstMatch) {
            if tap(button("Earnings goal")) { shot("earnings-goal"); cancel() } else { dismissPopup() }
        }
        if tap(app.buttons["Previous week"].firstMatch) {
            shotScrolling("earnings-last-week", pages: 5)
            if tap(text("Weekly recap")) { shotScrolling("earnings-weekly-recap", pages: 2); back() }
        }

        // Restaurants
        go("restaurants")
        shotScrolling("restaurants", pages: 2)
        if tap(text("Five Guys")) {
            shotScrolling("restaurant-detail", pages: 2)
            if tap(button("Merge with another restaurant")) { shot("restaurant-merge"); cancel() }
            back()
        }

        // Past shifts
        go("shifts")
        shot("past-shifts")
        if tap(app.cells.firstMatch) || tap(app.buttons.matching(NSPredicate(format: "label CONTAINS ' · '")).firstMatch) {
            shotScrolling("past-shift", pages: 3)
            if tap(app.buttons["Edit times"].firstMatch) { shot("past-shift-edit-times"); cancel() }
            back()
        }
        if tap(app.buttons["Add a shift"].firstMatch) { shot("past-shifts-add"); cancel() }

        // Account
        go("account")
        shotScrolling("account", pages: 4)
        if tap(text("Return location")) { shotScrolling("return-location", pages: 2); back() }
        if tap(text("Earnings goal per shift")) { shot("account-goal"); cancel() }
        if tap(text("Vehicle cost per mile")) { shot("account-vehicle-cost"); cancel() }
        if tap(app.buttons["About Your rules"].firstMatch) { shot("account-info-note"); cancel() }
        app.swipeUp(velocity: .slow); app.swipeUp(velocity: .slow); sleep(1)
        if tap(text("Privacy")) { shot("privacy"); back() }

        // Diagnostics (from the menu)
        go("diagnostics")
        shotScrolling("diagnostics", pages: 4)

        // Last: accepting the offer as a stacked order changes Home.
        go("home")
        if tap(button("Add as stacked order")) { shotScrolling("home-after-stacking", pages: 2) }
    }
}
