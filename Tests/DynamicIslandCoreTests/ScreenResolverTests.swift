import XCTest
@testable import DynamicIslandCore

final class ScreenResolverTests: XCTestCase {
    // Matches the layout the plan assumes: built-in at origin,
    // external to the right at +1440 origin. Both in "global bottom-left
    // origin" space to match NSScreen / NSEvent.mouseLocation convention.
    private let builtIn  = CGRect(x: 0,    y: 0, width: 1440, height: 900)
    private let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    func testPointInsideBuiltIn() {
        let r = ScreenResolver.screenIndex(for: CGPoint(x: 100, y: 100),
                                           in: [builtIn, external])
        XCTAssertEqual(r, 0)
    }

    func testPointInsideExternal() {
        let r = ScreenResolver.screenIndex(for: CGPoint(x: 2000, y: 500),
                                           in: [builtIn, external])
        XCTAssertEqual(r, 1)
    }

    func testPointOnBoundaryFavorsFirstMatch() {
        // The exact right edge of built-in is x=1440. CGRect.contains treats
        // maxX as exclusive. So x=1440 is inside external, not built-in.
        let r = ScreenResolver.screenIndex(for: CGPoint(x: 1440, y: 500),
                                           in: [builtIn, external])
        XCTAssertEqual(r, 1)
    }

    func testPointOutsideAllScreens() {
        let r = ScreenResolver.screenIndex(for: CGPoint(x: -10, y: 0),
                                           in: [builtIn, external])
        XCTAssertNil(r)
    }

    func testEmptyScreenArrayReturnsNil() {
        let r = ScreenResolver.screenIndex(for: .zero, in: [])
        XCTAssertNil(r)
    }
}
