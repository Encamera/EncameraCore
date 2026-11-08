//
//  BuildEnvironment.swift
//  EncameraCore
//

import Foundation

/// Build-time facts about this binary that change runtime defaults.
public enum BuildEnvironment {

    /// Info.plist key that carries the `ENABLE_TESTING_FEATURES` build value.
    public static let testingFeaturesInfoPlistKey = "EncameraTestingFeaturesEnabled"

    /// Whether this build turns on tester-facing features: captured debug logs,
    /// short passcode lockouts, the pre-login erase and the Feature Toggles
    /// screen.
    ///
    /// The value comes from the `ENABLE_TESTING_FEATURES` environment variable
    /// of the Xcode Cloud workflow that built the binary. Environment variables
    /// do not reach the device, so the app's Info.plist carries it as
    /// `$(ENABLE_TESTING_FEATURES)`, which the build expands, and
    /// `ci_scripts/ci_pre_xcodebuild.sh` also writes it there explicitly. An
    /// unset, empty or unrecognised value means `false`. Extensions have their
    /// own Info.plist without the key, so this is always `false` there.
    public static var isTestingFeaturesEnabled: Bool {
        isTestingFeaturesEnabled(infoDictionary: Bundle.main.infoDictionary)
    }

    static func isTestingFeaturesEnabled(infoDictionary: [String: Any]?) -> Bool {
        switch infoDictionary?[testingFeaturesInfoPlistKey] {
        case let value as Bool:
            return value
        case let value as String:
            return ["yes", "true", "1"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
        default:
            return false
        }
    }
}
