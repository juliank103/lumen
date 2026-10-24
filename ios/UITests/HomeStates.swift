import XCTest

/// Home in each of its states with the invented preview data (user, Oct 21: "I need a way to preview states of the app
/// on my computer"). Runs in every cloud build; the screenshots come down with the build (ios/dist/states) and
/// tools/states-gallery.py lays them out side by side.
final class HomeStates: XCTestCase {
    private var count = 100

    private func capture(_ state: String, extra: [String] = [], name: String? = nil, tap: String? = nil, open: String? = nil) {
        count += 2
        let app = XCUIApplication()
        app.launchArguments = ["-lumenPreview", "-dark", "-state", state] + extra
        app.launch()
        sleep(3)
        // Open a menu first (e.g. the order's ⋯ options).
        if let tap {
            let button = app.buttons[tap].firstMatch
            if button.waitForExistence(timeout: 4) { button.tap(); sleep(1) }
        }
        // Open a row by its text (e.g. an offer in the Offers list).
        if let open {
            let row = app.staticTexts[open].firstMatch
            if row.waitForExistence(timeout: 4) { row.tap(); sleep(2) }
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = String(format: "%03d-", count) + (name ?? state)
        attachment.lifetime = .keepAlways
        add(attachment)
        // Scrolled down too, for anything below the fold.
        app.swipeUp(velocity: .slow)
        sleep(1)
        let lower = XCTAttachment(screenshot: app.screenshot())
        lower.name = String(format: "%03d-", count + 1) + (name ?? state) + "-lower"
        lower.lifetime = .keepAlways
        add(lower)
        app.terminate()
    }

    func testHomeStates() {
        continueAfterFailure = true
        capture("waiting")
        capture("offer")
        capture("orderNew", name: "order-just-accepted")
        capture("orderAtStore", name: "order-at-first-store")
        capture("order")
        capture("orderOffer", name: "order-with-offer")
        capture("order", name: "order-options-menu", tap: "Order options")
        capture("waiting", extra: ["-tab", "1"], name: "offer-map-check", open: "Mendocino Farms")
        for (tab, name) in [(1, "offers"), (2, "earnings"), (5, "breakdown"), (6, "planner"), (7, "zones")] { capture("waiting", extra: ["-tab", String(tab)], name: name) }
    }
}
