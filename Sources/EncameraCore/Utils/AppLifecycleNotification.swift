import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The app-lifecycle notifications EncameraCore observes. On iOS these are
/// `UIApplication`'s own names. macOS has no matching lifecycle for the core to
/// follow, so there they are names nothing posts except tests.
public enum AppLifecycleNotification {
    #if canImport(UIKit)
    public static let didBecomeActive = UIApplication.didBecomeActiveNotification
    public static let willEnterForeground = UIApplication.willEnterForegroundNotification
    public static let didEnterBackground = UIApplication.didEnterBackgroundNotification
    public static let willResignActive = UIApplication.willResignActiveNotification
    public static let protectedDataWillBecomeUnavailable = UIApplication.protectedDataWillBecomeUnavailableNotification
    #else
    public static let didBecomeActive = Notification.Name("EncameraCore.AppLifecycle.didBecomeActive")
    public static let willEnterForeground = Notification.Name("EncameraCore.AppLifecycle.willEnterForeground")
    public static let didEnterBackground = Notification.Name("EncameraCore.AppLifecycle.didEnterBackground")
    public static let willResignActive = Notification.Name("EncameraCore.AppLifecycle.willResignActive")
    public static let protectedDataWillBecomeUnavailable = Notification.Name("EncameraCore.AppLifecycle.protectedDataWillBecomeUnavailable")
    #endif
}

/// Whether data protected while the phone is locked can be read: keychain items
/// stored `WhenUnlocked`, and files with complete protection. On iOS this is
/// `UIApplication.isProtectedDataAvailable`; macOS has no such lock, so there it
/// is always true.
@MainActor
public enum ProtectedDataAvailability {
    public static var isAvailable: Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }
}

/// Whether the app is running in the background, as it is in a background
/// background task run or after a background launch. On iOS this is
/// `UIApplication.applicationState == .background`; macOS has no such state, so
/// there it is always false.
@MainActor
public enum AppRunState {
    public static var isInBackground: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }
}
