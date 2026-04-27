import XCTest
@testable import DynamicIslandCore

final class HexColorTests: XCTestCase {

    // MARK: - parseHexColor

    func testParse_acceptsHashPrefix() {
        let rgb = parseHexColor("#FFFFFF")
        XCTAssertEqual(rgb, RGB(r: 1, g: 1, b: 1))
    }

    func testParse_acceptsNoHashPrefix() {
        let rgb = parseHexColor("FFFFFF")
        XCTAssertEqual(rgb, RGB(r: 1, g: 1, b: 1))
    }

    func testParse_lowercase() {
        let rgb = parseHexColor("#d9a673")
        XCTAssertNotNil(rgb)
        XCTAssertEqual(rgb!.r, 217.0 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(rgb!.g, 166.0 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(rgb!.b, 115.0 / 255.0, accuracy: 1e-9)
    }

    func testParse_trimsWhitespace() {
        XCTAssertEqual(parseHexColor("  #000000  "), RGB(r: 0, g: 0, b: 0))
    }

    func testParse_rejectsShort() {
        XCTAssertNil(parseHexColor("#FFF"))
    }

    func testParse_rejectsLong() {
        XCTAssertNil(parseHexColor("#FFFFFF00"))
    }

    func testParse_rejectsNonHex() {
        XCTAssertNil(parseHexColor("#GGGGGG"))
    }

    func testParse_rejectsEmpty() {
        XCTAssertNil(parseHexColor(""))
        XCTAssertNil(parseHexColor("#"))
    }

    // MARK: - encodeHexColor

    func testEncode_pureChannels() {
        XCTAssertEqual(encodeHexColor(RGB(r: 1, g: 0, b: 0)), "#FF0000")
        XCTAssertEqual(encodeHexColor(RGB(r: 0, g: 1, b: 0)), "#00FF00")
        XCTAssertEqual(encodeHexColor(RGB(r: 0, g: 0, b: 1)), "#0000FF")
    }

    func testEncode_clampsOverRange() {
        XCTAssertEqual(encodeHexColor(RGB(r: 1.5, g: -0.2, b: 0.5)), "#FF0080")
    }

    // MARK: - Round-trip

    func testRoundTrip_defaults() {
        for hex in ["#D9A673", "#A680F2", "#4CCC99"] {
            let rgb = parseHexColor(hex)
            XCTAssertNotNil(rgb, "should parse \(hex)")
            XCTAssertEqual(encodeHexColor(rgb!), hex)
        }
    }
}
