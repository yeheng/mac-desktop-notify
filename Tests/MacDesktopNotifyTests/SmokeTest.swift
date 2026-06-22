import XCTest
@testable import MacDesktopNotify

final class SmokeTest: XCTestCase {
    func testImportSucceeds() throws {
        // 仅验证测试 target 能链接并导入主 target
        // @testable import MacDesktopNotify is at file scope; if it failed,
        // this file would not compile. The XCTAssertTrue below is a no-op
        // that confirms the test runner itself is functional.
        XCTAssertTrue(true)
    }
}
