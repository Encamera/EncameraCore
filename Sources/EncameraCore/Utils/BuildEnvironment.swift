//
//  BuildEnvironment.swift
//  EncameraCore
//

import Foundation

/// Which distribution channel this binary came through, for defaults that
/// differ between TestFlight and the App Store.
public enum BuildEnvironment {

    /// TestFlight installs carry a sandbox receipt; App Store installs carry a
    /// production one. The receipt URL is deprecated for Swift callers in favour
    /// of StoreKit's async `AppTransaction`, which cannot answer a synchronous
    /// default, so the property is read through KVC.
    public static var isTestFlight: Bool {
        guard let receiptURL = Bundle.main.value(forKey: "appStoreReceiptURL") as? URL else {
            return false
        }
        return receiptURL.lastPathComponent == "sandboxReceipt"
    }
}
