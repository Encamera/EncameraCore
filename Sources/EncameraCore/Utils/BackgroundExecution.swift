import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Identifies one request for extra execution time after the app leaves the
/// foreground. Mirrors `UIBackgroundTaskIdentifier`, including `invalid` for a
/// request the system refused.
public struct BackgroundTaskID: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let invalid = BackgroundTaskID(rawValue: 0)
}

/// Begins and ends background tasks so long-running imports, moves, exports
/// and uploads can finish after the user leaves the app.
///
/// On iOS this is `UIApplication`'s background-task API. macOS does not
/// suspend a process that leaves the foreground, so there every request is
/// granted and ending it does nothing.
@MainActor
public enum BackgroundExecution {

    public static func begin(
        name: String,
        expirationHandler: (@MainActor @Sendable () -> Void)? = nil
    ) -> BackgroundTaskID {
        #if canImport(UIKit)
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
        return BackgroundTaskID(rawValue: identifier.rawValue)
        #else
        nextID += 1
        return BackgroundTaskID(rawValue: nextID)
        #endif
    }

    public static func end(_ task: BackgroundTaskID) {
        guard task != .invalid else { return }
        #if canImport(UIKit)
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: task.rawValue))
        #endif
    }

    #if !canImport(UIKit)
    private static var nextID = 0
    #endif
}
