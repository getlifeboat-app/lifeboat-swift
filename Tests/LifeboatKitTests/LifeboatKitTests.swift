import SwiftUI
import XCTest
@testable import LifeboatKit

final class LifeboatKitTests: XCTestCase {
    func testThemeUsesDefaultsAndIgnoresInvalidHex() {
        let layer = LifeboatAppearance(colors: .init(accent: "#ff6a00", text: "nothex"), radius: 99)
        let t = LifeboatTheme.resolve(.light, layers: [layer])
        XCTAssertEqual(t.radius, 28)
        XCTAssertEqual(t.accent, Color(lifeboatHex: "#ff6a00"))
        XCTAssertEqual(t.text, Color(lifeboatHex: "#111111"))
    }

    func testEmailCheck() {
        XCTAssertTrue(LifeboatPreferencesView.looksLikeEmail("a@b.co"))
        XCTAssertFalse(LifeboatPreferencesView.looksLikeEmail("nope"))
    }

    func testDecodesServerState() throws {
        let json = #"{"id":"sub_1","email":"a@b.co","status":"pending","pendingEmail":null,"preferences":{"critical":true,"updates":true,"promotions":false}}"#
        let s = try JSONDecoder().decode(LifeboatState.self, from: Data(json.utf8))
        XCTAssertEqual(s.status, .pending)
        XCTAssertTrue(s.isActive)
        XCTAssertFalse(s.preferences.promotions)
    }

    @MainActor
    func testRefusesSecretKeyFormat() {
        XCTAssertFalse(Lifeboat.shared.isConfigured)
    }
}
