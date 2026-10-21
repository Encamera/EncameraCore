import Foundation

extension Bundle {
    /// EncameraCore's resource bundle (localizations and the like). Tests name it
    /// through this property because inside the SwiftPM test target
    /// `Bundle.module` is the test target's own bundle, not this one.
    static var encameraCoreResources: Bundle { .module }
}
