//  Created by Alexander Freas on 04.03.24.
//

import Foundation
import Foundation

public struct AppVersion: Comparable {
    let majorVersion: Int
    let minorVersion: Int
    let patchVersion: Int

    static let zero = AppVersion(majorVersion: 0, minorVersion: 0, patchVersion: 0)

    init(majorVersion: Int, minorVersion: Int, patchVersion: Int) {
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.patchVersion = patchVersion
    }

    /// Parses "major.minor.patch"; missing trailing components read as 0.
    init?(_ string: String) {
        let components = string.split(separator: ".").map { Int($0) }
        guard (1...3).contains(components.count), !components.contains(nil) else {
            return nil
        }
        let numbers = components.compactMap { $0 } + Array(repeating: 0, count: 3 - components.count)
        self.init(majorVersion: numbers[0], minorVersion: numbers[1], patchVersion: numbers[2])
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.majorVersion, lhs.minorVersion, lhs.patchVersion) < (rhs.majorVersion, rhs.minorVersion, rhs.patchVersion)
    }
}

public class LaunchCountUtils: DebugPrintable {

    private static var currentVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    public static func recordCurrentVersionLaunch() {

        var launchCount = UserDefaultUtils.dictionary(forKey: .launchCountKey) as? [String: Int] ?? [String: Int]()
        launchCount[currentVersion] = (launchCount[currentVersion] ?? 0) + 1
        UserDefaultUtils.set(launchCount, forKey: .launchCountKey)

        UserDefaultUtils.set(currentVersion, forKey: .lastVersionKey)
    }

    public static func fetchCurrentVersionLaunchCount() -> Int {

        let launchCount = UserDefaultUtils.dictionary(forKey: .launchCountKey) as? [String: Int] ?? [String: Int]()
        return launchCount[currentVersion] ?? 0
    }

    public static func isUpgradeLaunch() -> Bool {

        if let lastVersion = UserDefaultUtils.string(forKey: .lastVersionKey), lastVersion != currentVersion {
            return true
        }
        return false
    }

    /// The version the app last launched as, and the one it is launching as now. On a first
    /// launch both are the current version. Must be read before `recordCurrentVersionLaunch()`,
    /// which overwrites the stored previous version.
    public static func launchVersionChange() -> (from: AppVersion, to: AppVersion) {
        let current = AppVersion(currentVersion) ?? .zero
        guard let lastVersion = UserDefaultUtils.string(forKey: .lastVersionKey) else {
            return (current, current)
        }
        return (AppVersion(lastVersion) ?? .zero, current)
    }
}
