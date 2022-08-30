//
//  NotificationUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation
import UIKit
import Combine

struct NotificationUtils {
    
    private static var noOp = false
    
    static var didBecomeActivePublisher: AnyPublisher<Notification, Never> {
        
        return publisher(for: UIApplication.didBecomeActiveNotification)
    }
    
    static var didEnterBackgroundPublisher: AnyPublisher<Notification, Never> {
        return publisher(for: UIApplication.didEnterBackgroundNotification)
            
    }
    
    static var willResignActivePublisher: AnyPublisher<Notification, Never> {
        return publisher(for: UIApplication.willResignActiveNotification)
    }
    
    static var orientationDidChangePublisher: AnyPublisher<Notification, Never> {
        return publisher(for: UIDevice.orientationDidChangeNotification)
    }
    
    static var systemClockDidChangePublisher: AnyPublisher<Notification, Never> {
        return publisher(for: .NSSystemClockDidChange)
    }
    
    private static func publisher(for notifType: Notification.Name) -> AnyPublisher<Notification, Never> {
        guard noOp == false else {
            return PassthroughSubject().eraseToAnyPublisher()
        }
        return NotificationCenter.default
            .publisher(for: notifType)
            .eraseToAnyPublisher()
    }
}
