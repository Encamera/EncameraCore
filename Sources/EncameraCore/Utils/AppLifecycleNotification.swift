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
    public static let didFinishLaunching = UIApplication.didFinishLaunchingNotification
    #else
    public static let didBecomeActive = Notification.Name("EncameraCore.AppLifecycle.didBecomeActive")
    public static let willEnterForeground = Notification.Name("EncameraCore.AppLifecycle.willEnterForeground")
    public static let didEnterBackground = Notification.Name("EncameraCore.AppLifecycle.didEnterBackground")
    public static let willResignActive = Notification.Name("EncameraCore.AppLifecycle.willResignActive")
    public static let didFinishLaunching = Notification.Name("EncameraCore.AppLifecycle.didFinishLaunching")
    #endif
}
