import XCTest
@testable import CodexSwitchboard

final class StagingIsolationTests: XCTestCase {
    func testStorageNamespaceAcceptsSideBySideCandidateName() {
        XCTAssertEqual(
            AppStorage.normalizedStorageNamespace("CodexSwitchboardForkRC"),
            "CodexSwitchboardForkRC"
        )
    }

    func testStorageNamespaceRejectsPathTraversal() {
        XCTAssertEqual(
            AppStorage.normalizedStorageNamespace("../CodexSwitchboard"),
            "CodexSwitchboard"
        )
        XCTAssertEqual(
            AppStorage.normalizedStorageNamespace(""),
            "CodexSwitchboard"
        )
    }

    func testBuildScriptWritesStorageNamespaceIntoBundle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("build-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("STORAGE_NAMESPACE"))
        XCTAssertTrue(script.contains("CodexSwitchboardStorageNamespace"))
    }
}
