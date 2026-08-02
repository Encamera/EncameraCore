//
//  MultiDeviceDisableWarning.swift
//  EncameraCore
//
//  The copy shown before turning iCloud Multi-Device Mode OFF (ENC-87).
//
//  De-syncing a keychain item tombstones it: it is removed from iCloud and from
//  every other device on the account. The device performing the flip keeps its
//  local copy; a device that only ever had the synced copy does not. This type
//  turns the advisory device roster into copy that says that truthfully.
//

import Foundation

/// Builds the warning for turning Multi-Device Mode off.
///
/// Separated from the view model so the wording rules — which are the whole
/// point of the ticket — are unit-testable without SwiftUI.
public enum MultiDeviceDisableWarning {

    /// The devices, other than this one, that the roster knows about.
    ///
    /// The current device is excluded because it keeps its local copy: naming it
    /// would tell the user they are about to lose access on the device they are
    /// holding, which is false.
    ///
    /// **The roster is advisory, never authoritative** (see `MultiDeviceState`):
    /// it merges last-writer-wins rather than as a CRDT, has no removal API, and
    /// is capped at 10 entries. So it can both over-report (a wiped device never
    /// removes itself) and under-report (a concurrent write can drop an entry).
    /// Copy built from it may therefore *name examples*, but must never make a
    /// claim about the complete set — above all never "no other devices are
    /// affected", which absence of entries cannot establish.
    public static func affectedDeviceNames(
        state: MultiDeviceState?,
        currentDeviceID: String
    ) -> [String] {
        let names = (state?.devices ?? [])
            .filter { $0.deviceID != currentDeviceID }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Deduplicated because `DeviceIDProvider.deviceName()` is
        // `UIDevice.current.name`, which on iOS 16+ without the
        // user-assigned-device-name entitlement is the generic model string —
        // every entry can literally be "iPhone". Listing "iPhone, iPhone" reads
        // like a bug; one "iPhone" under an "including …" phrasing stays true.
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    /// The warning text.
    ///
    /// With names available the copy says "including <names>" — deliberately
    /// non-exhaustive, so it stays true whether the roster is short a device or
    /// naming one that no longer exists. With no names it drops to copy that
    /// describes the consequence without counting anything. Neither form ever
    /// asserts that nothing else is affected.
    public static func text(
        state: MultiDeviceState?,
        currentDeviceID: String
    ) -> String {
        let names = affectedDeviceNames(state: state, currentDeviceID: currentDeviceID)
        guard !names.isEmpty, let list = formattedList(names) else {
            return L10n.Settings.MultiDeviceMode.disableGenericWarning
        }
        return L10n.Settings.MultiDeviceMode.disableDevicesWarning(list)
    }

    private static func formattedList(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let formatter = ListFormatter()
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }
}
