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
    
    static var didBecomeActivePublisher: AnyPublisher<Notification, Never> {
        
        return NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .eraseToAnyPublisher()
    }
    
    static var didEnterBackgroundPublisher: AnyPublisher<Notification, Never> {
        return NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .eraseToAnyPublisher()
    }
    
    static var willResignActivePublisher: AnyPublisher<Notification, Never> {
        return NotificationCenter.default
            .publisher(for: UIApplication.willResignActiveNotification)
            .eraseToAnyPublisher()
    }
    
    static var orientationDidChangePublisher: AnyPublisher<Notification, Never> {
        return NotificationCenter.default
            .publisher(for: UIDevice.orientationDidChangeNotification)
            .eraseToAnyPublisher()
    }
    
    static var systemClockDidChangePublisher: AnyPublisher<Notification, Never> {
        return NotificationCenter.default
            .publisher(for: .NSSystemClockDidChange)
            .eraseToAnyPublisher()
    }
}
