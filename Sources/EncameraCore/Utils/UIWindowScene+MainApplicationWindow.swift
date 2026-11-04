#if canImport(UIKit)
import UIKit

public extension UIWindowScene {

    /// The scene's own content window, at `.normal` level. The lock screen and
    /// the privacy cover are windows above it, and the lock screen is key while
    /// it is up, so the key window is not where the app's content belongs.
    var mainApplicationWindow: UIWindow? {
        windows.first { $0.windowLevel == .normal && !$0.isHidden }
    }

    /// The top of the main application window's presentation stack, which is
    /// where the app presents share sheets, players and alerts. While the app
    /// is locked these then open under the lock screen rather than over it.
    var topmostApplicationViewController: UIViewController? {
        guard var current = mainApplicationWindow?.rootViewController else { return nil }
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}
#endif
