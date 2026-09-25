//
//  File.swift
//  EncameraCore
//
//  Created by Alexander Freas on 26.11.24.
//

import Foundation
import UIKit

extension UIApplication {
    public static func topMostViewController() -> UIViewController? {
        let connectedScenes = UIApplication.shared.connectedScenes

        let windowScene = connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene

        if let rootViewController = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            var currentVC = rootViewController

            while let presentedVC = currentVC.presentedViewController {
                currentVC = presentedVC
            }

            return currentVC
        }

        return nil
    }

}
