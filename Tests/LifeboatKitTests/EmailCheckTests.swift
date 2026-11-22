import XCTest
@testable import LifeboatKit

final class EmailCheckTests: XCTestCase {
    func testSuggestsCommonTypos() {
        XCTAssertEqual(LifeboatEmailCheck.suggestion(for: "asha@gmial.com"), "asha@gmail.com")
        XCTAssertEqual(LifeboatEmailCheck.suggestion(for: "asha@gmail.con"), "asha@gmail.com")
        XCTAssertEqual(LifeboatEmailCheck.suggestion(for: "Asha@Hotmial.com "), "asha@hotmail.com")
        XCTAssertEqual(LifeboatEmailCheck.suggestion(for: "asha@outlok.com"), "asha@outlook.com")
        XCTAssertEqual(LifeboatEmailCheck.suggestion(for: "asha@yaho.com"), "asha@yahoo.com")
    }

    func testLeavesRealAddressesAlone() {
        XCTAssertNil(LifeboatEmailCheck.suggestion(for: "asha@gmail.com"))
        XCTAssertNil(LifeboatEmailCheck.suggestion(for: "asha@example.com"))
        XCTAssertNil(LifeboatEmailCheck.suggestion(for: "asha@tapal.app"))
        XCTAssertNil(LifeboatEmailCheck.suggestion(for: "asha@company.co.in"))
        XCTAssertNil(LifeboatEmailCheck.suggestion(for: "not-an-email"))
    }
}
