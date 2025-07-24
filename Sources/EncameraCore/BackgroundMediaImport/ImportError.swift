//
//  ImportError.swift
//  EncameraCore
//
//  Created by Alexander Freas on 24.07.25.
//
import Foundation
import BackgroundTasks
import Combine
import UIKit




// MARK: - Supporting Types

public enum ImportError: Error {
    case configurationError
    case taskNotFound
    case operationCancelled
}
