//
//  NotificationUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Combine
import AVFoundation

public struct NotificationUtils {

    private static var noOp = false

    enum Keys {
        static var hardwareButtonPressedKey = "hardwareButtonPressedKey"
    }

    public static func sendHardwareButtonPressed() {
        NotificationCenter.default.post(name: Notification.Name(Keys.hardwareButtonPressedKey), object: "pressed")
    }

    public static var hardwareButtonPressedPublisher: AnyPublisher<Notification, Never> {
        return publisher(for: Notification.Name(Keys.hardwareButtonPressedKey))
    }

    public static var didBecomeActivePublisher: AnyPublisher<Notification, Never> {

        return publisher(for: AppLifecycleNotification.didBecomeActive)
    }

    public static var willEnterForegroundPublisher: AnyPublisher<Notification, Never> {
        return publisher(for: AppLifecycleNotification.willEnterForeground)
    }

    public static var didEnterBackgroundPublisher: AnyPublisher<Notification, Never> {
        return publisher(for: AppLifecycleNotification.didEnterBackground)
    }

    public static var willResignActivePublisher: AnyPublisher<Notification, Never> {
        return publisher(for: AppLifecycleNotification.willResignActive)
    }

    #if canImport(UIKit)
    public static var orientationDidChangePublisher: AnyPublisher<Notification, Never> {
        return publisher(for: UIDevice.orientationDidChangeNotification)
    }
    #endif

    private static func publisher(for notifType: Notification.Name) -> AnyPublisher<Notification, Never> {
        guard noOp == false else {
            return PassthroughSubject().eraseToAnyPublisher()
        }
        return NotificationCenter.default
            .publisher(for: notifType)
            .eraseToAnyPublisher()
    }
}
