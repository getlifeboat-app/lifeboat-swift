import SwiftUI
import XCTest
@testable import LifeboatKit

final class AppearanceTests: XCTestCase {
    func testDefaultsAreUnchanged() {
        let t = LifeboatTheme.resolve(.light, layers: [])
        XCTAssertEqual(t.error, .red)
        XCTAssertEqual(t.titleDesign, .default)
        XCTAssertEqual(t.titleWeight, .bold)
        XCTAssertNil(t.titleFontName)
        XCTAssertNil(t.inboxSymbol)
    }

    func testAppLayerSetsErrorTitleAndInboxSymbol() {
        let app = LifeboatAppearance(colors: .init(error: "#B3261E"), colorsDark: .init(error: "#FF8A80"),
                                     titleDesign: "serif", titleWeight: "regular", inboxSymbol: "envelope")
        let light = LifeboatTheme.resolve(.light, layers: [nil, app])
        let dark = LifeboatTheme.resolve(.dark, layers: [nil, app])
        XCTAssertEqual(light.error, Color(lifeboatHex: "#B3261E"))
        XCTAssertEqual(dark.error, Color(lifeboatHex: "#FF8A80"))
        XCTAssertEqual(light.titleDesign, .serif)
        XCTAssertEqual(light.titleWeight, .regular)
        XCTAssertEqual(light.inboxSymbol, "envelope")
    }

    func testCodeWinsOverDashboardAndBadValuesAreIgnored() {
        let dashboard = LifeboatAppearance(colors: .init(error: "#123456"), titleDesign: "rounded")
        let app = LifeboatAppearance(colors: .init(error: "red"), titleDesign: "serif", titleFontName: "Georgia")
        let t = LifeboatTheme.resolve(.light, layers: [dashboard, app])
        XCTAssertEqual(t.error, Color(lifeboatHex: "#123456"), "an invalid hex in code keeps the dashboard's value")
        XCTAssertEqual(t.titleDesign, .serif)
        XCTAssertEqual(t.titleFontName, "Georgia")
    }
}
