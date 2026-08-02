//
//  MultiDeviceKeyConflict.swift
//  EncameraCore
//
//  Describes the "another key is already in this iCloud account" situation that
//  the Multi-Device Mode confirmation has to tell the user about (ENC-86).
//

import Foundation

/// A key on this device and a *different* key already known to the iCloud
/// account. Detected by comparing the locally stored key fingerprints against
/// the always-synced `MultiDeviceState.keyFingerprints` record (ENC-71).
///
/// This is the situation behind the shipping data-loss reports ("I turned on my
/// iPad and lost all my data"). Since ENC-69 a key's identity is its
/// fingerprint, so two different keys occupy two different keychain items and
/// can coexist — but the user still has to be told, because which key a device
/// writes new media with is a decision only they can make.
///
/// Advisory only: `MultiDeviceState` is a last-writer-merges record and is not
/// authoritative. Nothing destructive may be decided from it — this type exists
/// solely to make the warning copy truthful.
public struct MultiDeviceKeyConflict: Equatable {

    /// Fingerprint of the key this device is currently using, if it has one.
    public let localFingerprint: String?

    /// Fingerprints the account knows about that this device does not hold.
    public let remoteFingerprints: [String]

    public init(localFingerprint: String?, remoteFingerprints: [String]) {
        self.localFingerprint = localFingerprint
        self.remoteFingerprints = remoteFingerprints
    }

    /// Short human-readable form of the local key, e.g. `54E0-7B52`.
    public var localDisplayLabel: String? {
        localFingerprint.flatMap { KeyFingerprint.displayLabel(fingerprintHex: $0) }
    }

    /// Short human-readable forms of the remote keys, in record order.
    public var remoteDisplayLabels: [String] {
        remoteFingerprints.compactMap { KeyFingerprint.displayLabel(fingerprintHex: $0) }
    }
}
