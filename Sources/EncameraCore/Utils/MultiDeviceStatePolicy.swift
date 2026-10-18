//
//  MultiDeviceStatePolicy.swift
//  EncameraCore
//

import Foundation

/// Whether this process writes the always-synced `MultiDeviceState` record.
///
/// On by default. The app turns it off under UI test mode (see
/// `UITestMode.recordsMultiDeviceState`): the record syncs unconditionally
/// and its has-used evidence is sticky, so an ordinary UI test must not leave
/// account-wide state behind. It lives here rather than in the app because
/// `KeyMintingManager` writes the record from inside `KeychainManager`, where
/// the app's launch arguments are out of reach.
public enum MultiDeviceStatePolicy {
    nonisolated(unsafe) public static var publishesState = true
}
