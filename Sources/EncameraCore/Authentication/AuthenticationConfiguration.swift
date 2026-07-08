//
//  AuthenticationConfiguration.swift
//  EncameraCore
//
//  Created by Alexander Freas on 03.07.26.
//

import Foundation


public struct AuthenticationConfiguration: Codable, Equatable {
    public enum AuthenticationType: Codable, Hashable {
        case biometrics
        case passcode(PasscodeType)
    }

    public private(set) var enabledTypes: Set<AuthenticationType>

    public init(enabledTypes: [AuthenticationType]) {
        self.enabledTypes = Set(enabledTypes)
    }

    /// The enabled passcode type, if any. There is at most one — see
    /// `addAuthenticationType`.
    public var passcodeType: PasscodeType? {
        for case let .passcode(type) in enabledTypes {
            return type
        }
        return nil
    }

    public mutating func addAuthenticationType(_ type: AuthenticationType) {
        // Only one passcode entry may exist: replace any existing one so the
        // set can't hold two .passcode cases with different associated values.
        if case .passcode = type, let existing = passcodeType {
            enabledTypes.remove(.passcode(existing))
        }
        self.enabledTypes.insert(type)
    }

    public mutating func removeAuthenticationType(_ type: AuthenticationType) {
        self.enabledTypes.remove(type)
    }

    public func isTypeEnabled(_ type: AuthenticationType) -> Bool {
        return enabledTypes.contains(type)
    }
}
