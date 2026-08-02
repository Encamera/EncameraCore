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

    // MARK: - Decoding

    /// Drops individual entries this build cannot represent instead of failing
    /// the whole configuration.
    ///
    /// This item ALWAYS syncs, so a device running a newer build can put a
    /// passcode type (or an authentication type) in here that an older build
    /// has never heard of. With the synthesised decoder one such entry threw,
    /// `getAuthenticationConfiguration()` returned nil, and the device behaved
    /// as if no authentication had ever been configured. Skipping the unknown
    /// entry keeps the rest — notably the biometrics flag — readable.
    ///
    /// Encoding stays synthesised, so the on-disk shape is unchanged and an
    /// entry this build dropped is only lost if this device rewrites the item.
    private enum CodingKeys: String, CodingKey {
        case enabledTypes
    }

    private struct LenientAuthenticationType: Decodable {
        let value: AuthenticationType?

        init(from decoder: Decoder) throws {
            value = try? AuthenticationType(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([LenientAuthenticationType].self, forKey: .enabledTypes)
        self.enabledTypes = Set(decoded.compactMap(\.value))
    }
}
