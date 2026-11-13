import XCTest

/// Presses the Siri Remote on a real Apple TV and logs which element holds the focus after each press, with a
/// screenshot at the interesting steps (attached to the result bundle). Run against the dev build:
///   xcodebuild test -scheme XTPlayerTVUITests -destination 'id=<Apple TV>' DEVELOPMENT_TEAM=<team>
/// It checks what cannot be seen from code: where the focus engine actually goes.
final class TVNavigationTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.xuanthanhtnt.xtplayer.dev")
    private let remote = XCUIRemote.shared

    override func setUp() {
        continueAfterFailure = true
    }

    /// Menu: up at the top of a page stays put, left at the edge opens the menu on the section shown, right
    /// closes it, Settings opens its groups and a group's panel.
    func testMenuNavigation() {
        app.launch()
        sleep(5)
        step("launch")
        press(.up, "up at the top of Home")
        press(.up, "up again")
        press(.left, "left")
        press(.left, "left again")
        press(.left, "left a third time")
        snap("menu")
        press(.right, "right closes the menu")
        press(.down, "down to the shelf")
        press(.left, "left from the first card")
        press(.left, "left again")
        for _ in 0..<6 { remote.press(.down); usleep(400_000) }
        step("down to the bottom of the menu")
        press(.select, "select Cài đặt")
        press(.down, "down to the first group")
        snap("settings")
        press(.right, "right into the panel")
        press(.down, "down in the panel")
        press(.select, "select a choice")
        snap("panel")
        press(.menu, "menu back to the group")
        press(.menu, "menu closes Settings")
        press(.menu, "menu again")
        snap("end")
    }

    // MARK: Helpers

    private func press(_ button: XCUIRemote.Button, _ what: String) {
        remote.press(button)
        usleep(900_000)
        step(what)
    }

    private func step(_ what: String) {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        let description = focused.exists ? "\(focused.elementType.rawValue) '\(focused.label)'" : "nothing"
        print("[ui] \(what): \(description)")
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
