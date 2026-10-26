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

        XCTAssertTrue(script.contains(
            #"plutil -replace CodexSwitchboardStorageNamespace -string "$STORAGE_NAMESPACE" "$PLIST""#
        ))
    }

    func testEmptyOrUnusableEnvironmentNamespaceKeepsTheBundleNamespace() {
        XCTAssertEqual(
            AppStorage.resolvedStorageNamespace(environmentValue: "", bundleValue: "CodexSwitchboardForkRC"),
            "CodexSwitchboardForkRC"
        )
        XCTAssertEqual(
            AppStorage.resolvedStorageNamespace(environmentValue: "a/b", bundleValue: "CodexSwitchboardForkRC"),
            "CodexSwitchboardForkRC"
        )
        XCTAssertEqual(
            AppStorage.resolvedStorageNamespace(environmentValue: "Staging", bundleValue: "CodexSwitchboardForkRC"),
            "Staging"
        )
        XCTAssertEqual(AppStorage.resolvedStorageNamespace(environmentValue: nil, bundleValue: nil), "CodexSwitchboard")
    }
}
