import XCTest

/// Home in each of its states with the invented preview data (user, Oct 21: "I need a way to preview states of the app
/// on my computer"). Runs in every cloud build; the screenshots come down with the build (ios/dist/states) and
/// tools/states-gallery.py lays them out side by side.
final class HomeStates: XCTestCase {
    private var count = 100

    private func capture(_ state: String, extra: [String] = [], name: String? = nil) {
        count += 2
        let app = XCUIApplication()
        app.launchArguments = ["-lumenPreview", "-dark", "-state", state] + extra
        app.launch()
        sleep(3)
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
        capture("order")
        capture("orderOffer", name: "order-with-offer")
        for (tab, name) in [(1, "offers"), (2, "earnings")] { capture("waiting", extra: ["-tab", String(tab)], name: name) }
    }
}
