//
//  ICloudDriveBlobMigrationCellularPreference.swift
//  EncameraCore
//
//  The user's choice to let the iCloud Drive blob migration use cellular data.
//  Without it the blob migration, its download-ahead and its CloudKit requests
//  run only on an unmetered network (`NetworkMonitor.isOnUnmeteredNetwork`);
//  with it they run on any connected network. Nothing else in the app reads it.
//  Stored locally in `UserDefaultKey.useCellularForICloudDriveBlobMigration`, never
//  synced: it is a choice about this device's data plan.
//

import Foundation

public enum ICloudDriveBlobMigrationCellularPreference {

    /// Posted on `NotificationCenter.default` when `isAllowed` changes.
    public static let didChange = Notification.Name("ICloudDriveBlobMigrationCellularPreference.didChange")

    /// Whether the blob migration may use cellular data. Off until the user turns it on.
    public static var isAllowed: Bool {
        get { UserDefaultUtils.bool(forKey: .useCellularForICloudDriveBlobMigration) }
        set {
            guard newValue != isAllowed else { return }
            UserDefaultUtils.set(newValue, forKey: .useCellularForICloudDriveBlobMigration)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Whether the blob migration may transfer on a network in `state`: an unmetered
    /// one always, any connected one while cellular is allowed.
    public static func permitsTransfer(on state: NetworkMonitor.State, cellularAllowed: Bool = isAllowed) -> Bool {
        state.isOnUnmeteredNetwork || (cellularAllowed && state.isConnected)
    }

    /// Whether the blob migration may transfer on the device's current network.
    public static var permitsTransferNow: Bool {
        permitsTransfer(on: NetworkMonitor.shared.currentState)
    }
}
