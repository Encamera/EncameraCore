//
//  KeyMediaAssociationUtil.swift
//  EncameraCore
//
//  Which albums each key encrypts and how much media each album holds, so a
//  key's importance can be judged by how much would be lost without it.
//

import Foundation

public struct KeyMediaAssociationReport {

    /// Where a key was generated, from the synced `MultiDeviceState`.
    public enum Origin: Equatable {
        case thisDevice
        /// `name` is nil when the device has since dropped off the roster.
        case otherDevice(name: String?)
        /// On the account, but no device has claimed it: generated before
        /// origins were recorded, or its device has not published it yet.
        case unknownDevice
        /// Not in the multi-device state at all.
        case unrecorded
    }

    public struct AlbumUsage: Identifiable {
        public let album: Album
        public let mediaCount: Int

        public var id: String { album.id }
    }

    public struct KeyUsage: Identifiable {
        public let key: PrivateKey
        public let origin: Origin
        /// Largest album first.
        public let albums: [AlbumUsage]

        public var id: String { key.keyFingerprint }

        public var totalMediaCount: Int {
            albums.reduce(0) { $0 + $1.mediaCount }
        }
    }

    /// Every key, the one that decrypts the most media first. A key no album
    /// uses is still listed, with no albums.
    public let keys: [KeyUsage]

    public func usage(forKeyFingerprint keyFingerprint: String) -> KeyUsage? {
        keys.first { $0.key.keyFingerprint == keyFingerprint }
    }
}

public enum KeyMediaAssociationUtil {

    /// Groups `albums` under the key that encrypts each one, and resolves each
    /// key's origin against `multiDeviceState`. An album whose key is not in
    /// `keys` still gets an entry, under the album's own key.
    public static func report(keys: [PrivateKey],
                              albums: [Album],
                              multiDeviceState: MultiDeviceState?,
                              currentDeviceID: String,
                              mediaCount: (Album) -> Int) -> KeyMediaAssociationReport {
        var keysByLabel: [String: PrivateKey] = [:]
        var order: [String] = []
        var albumsByLabel: [String: [KeyMediaAssociationReport.AlbumUsage]] = [:]

        func register(_ key: PrivateKey) -> String {
            let label = key.keyFingerprint
            if keysByLabel[label] == nil {
                keysByLabel[label] = key
                order.append(label)
            }
            return label
        }

        keys.forEach { _ = register($0) }
        for album in albums {
            let label = register(album.key)
            albumsByLabel[label, default: []].append(.init(album: album, mediaCount: mediaCount(album)))
        }

        let usages = order.compactMap { label -> KeyMediaAssociationReport.KeyUsage? in
            guard let key = keysByLabel[label] else { return nil }
            let albums = (albumsByLabel[label] ?? []).sorted { $0.mediaCount > $1.mediaCount }
            return .init(key: key,
                         origin: origin(of: label, in: multiDeviceState, currentDeviceID: currentDeviceID),
                         albums: albums)
        }
        return KeyMediaAssociationReport(keys: usages.sorted { $0.totalMediaCount > $1.totalMediaCount })
    }

    /// The report for every stored key and every album, hidden ones included.
    public static func report(keyManager: KeyManager, albumManager: AlbumManaging) -> KeyMediaAssociationReport {
        report(keys: (try? keyManager.storedKeys()) ?? [],
               albums: albumManager.fetchAlbumsFromSources(includingHidden: true),
               multiDeviceState: keyManager.getMultiDeviceState(),
               currentDeviceID: DeviceIDProvider.deviceID(),
               mediaCount: albumManager.albumMediaCount(album:))
    }

    static func origin(of keyFingerprint: String,
                       in state: MultiDeviceState?,
                       currentDeviceID: String) -> KeyMediaAssociationReport.Origin {
        guard let state, state.keyFingerprints.contains(keyFingerprint) else {
            return .unrecorded
        }
        guard let deviceID = state.keyOrigins[keyFingerprint] else {
            return .unknownDevice
        }
        if deviceID == currentDeviceID {
            return .thisDevice
        }
        return .otherDevice(name: state.devices.first { $0.deviceID == deviceID }?.name)
    }
}
