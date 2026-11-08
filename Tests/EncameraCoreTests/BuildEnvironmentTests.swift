import XCTest
@testable import EncameraCore

final class BuildEnvironmentTests: XCTestCase {

    private func enabled(_ value: Any?) -> Bool {
        let info: [String: Any]? = value.map { [BuildEnvironment.testingFeaturesInfoPlistKey: $0] }
        return BuildEnvironment.isTestingFeaturesEnabled(infoDictionary: info)
    }

    func testMissingKeyIsDisabled() {
        XCTAssertFalse(BuildEnvironment.isTestingFeaturesEnabled(infoDictionary: nil))
        XCTAssertFalse(BuildEnvironment.isTestingFeaturesEnabled(infoDictionary: [:]))
    }

    func testUnsetBuildSettingExpandsToEmptyAndIsDisabled() {
        XCTAssertFalse(enabled(""))
    }

    func testTruthyStringsEnable() {
        for value in ["YES", "yes", "true", "TRUE", "1", " YES "] {
            XCTAssertTrue(enabled(value), value)
        }
    }

    func testOtherStringsDisable() {
        for value in ["NO", "false", "0", "$(ENABLE_TESTING_FEATURES)", "enabled"] {
            XCTAssertFalse(enabled(value), value)
        }
    }

    func testBooleanValues() {
        XCTAssertTrue(enabled(true))
        XCTAssertFalse(enabled(false))
    }
}
