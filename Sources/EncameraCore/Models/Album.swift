//
//  Album.swift
//
//
//  Created by Alexander Freas on 26.10.23.
//

import Foundation
import Combine
import Sodium

public struct Album: Codable, Identifiable, Hashable {

    public init(name: String, storageOption: StorageType, creationDate: Date, key: PrivateKey, albumID: String? = nil) {
        self.name = name
        self.storageOption = storageOption
        self.creationDate = creationDate
        self.key = key
        self.albumID = albumID
        self.encryptedName = encryptedPathComponent
    }

    public init(encryptedName: String, storageOption: StorageType, creationDate: Date, key: PrivateKey, albumID: String? = nil) {
        self.storageOption = storageOption
        self.creationDate = creationDate
        self.key = key
        self.albumID = albumID
        self.name = Self.decryptAlbumName(encryptedName, key: key)
        self.encryptedName = encryptedName
    }

    public var key: PrivateKey
    public var name: String {
        didSet {
            encryptedName = nil
            encryptedName = encryptedPathComponent
        }
    }
    public var storageOption: StorageType
    public var creationDate: Date
    private var encryptedName: String?

    /// A CloudKit album's identity: minted once when the album becomes a CloudKit
    /// album and never derived from its name, so a rename leaves it unchanged. It is
    /// the `EncAlbum` record name and names every per-album store on this device.
    /// Non-nil exactly when `storageOption == .cloudKit`.
    public var albumID: String?

    /// Keys the media index, the sidecars, migration plans and `currentAlbumID`.
    /// A CloudKit album is keyed by its `albumID`; a local album by its name, since
    /// its directory is its identity.
    public var id: String {
        if let albumID {
            return "\(albumID)_\(StorageType.cloudKit.rawValue)"
        }
        return "\(name)_\(storageOption.rawValue)"
    }

    /// True when the album's name is ciphertext its own key cannot open: a
    /// directory album named under a key this device does not hold, opened under
    /// the key that reads its media. `name` then holds that ciphertext, which keeps
    /// the album's identity and directory stable, and views show `displayName`.
    ///
    /// Only a string shaped like an encrypted name (the prefix plus a decodable
    /// header and tag) is tested, so a user's own name such as "Album_2024" is
    /// never mistaken for one.
    public var isNameUnavailable: Bool {
        Self.isWellFormedEncryptedName(name) && Self.decryptedAlbumName(name, key: key) == nil
    }

    /// The name to show the user.
    public var displayName: String {
        isNameUnavailable ? L10n.MissingKey.albumNameUnavailable : name
    }

    private static func isWellFormedEncryptedName(_ candidate: String) -> Bool {
        guard candidate.hasPrefix("Album_") else { return false }
        let base64 = candidate.dropFirst("Album_".count).replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64) else { return false }
        return data.count > SecretStream.XChaCha20Poly1305.HeaderBytes + SecretStream.XChaCha20Poly1305.ABytes
    }

    public var storageURL: URL {
        storageOption.modelForType.init(album: self).baseURL
    }

    /// The same album (same name + key) re-pointed at CloudKit storage under
    /// `albumID` — the single owner of "make the `.cloudKit` twin of this album",
    /// used by the migration engine and the album flip so the semantics live in one
    /// place.
    ///
    /// A legacy album whose directory name is plaintext gets a real ciphertext name
    /// here, because the twin's `encryptedPathComponent` is what reaches CloudKit and
    /// `album.json` as `encName`. Existing ciphertext is kept as it is, even when
    /// `key` cannot open it: it may belong to another key the device holds.
    public static func cloudKitTwin(of album: Album, albumID: String) -> Album {
        var twin = album
        twin.storageOption = .cloudKit
        twin.albumID = albumID
        if !twin.encryptedPathComponent.hasPrefix("Album_") {
            twin.name = album.name
        }
        return twin
    }

    /// The same album (same name + key) re-pointed at local storage. A local album
    /// is identified by its directory, so the CloudKit `albumID` is dropped.
    public static func localTwin(of album: Album) -> Album {
        var twin = album
        twin.storageOption = .local
        twin.albumID = nil
        return twin
    }

    // MARK: - Equality

    /// A CloudKit album compares by `albumID` plus the fields a view renders, and
    /// leaves out the name ciphertext, which differs on every encryption of the same
    /// name. `name` stays in so SwiftUI still sees a rename as a change. Albums
    /// without an `albumID` compare every stored field.
    public static func == (lhs: Album, rhs: Album) -> Bool {
        guard lhs.albumID == rhs.albumID,
              lhs.name == rhs.name,
              lhs.storageOption == rhs.storageOption,
              lhs.creationDate == rhs.creationDate,
              lhs.key == rhs.key else { return false }
        return lhs.albumID != nil || lhs.encryptedName == rhs.encryptedName
    }

    public func hash(into hasher: inout Hasher) {
        if let albumID {
            hasher.combine(albumID)
            hasher.combine(storageOption)
            return
        }
        hasher.combine(key)
        hasher.combine(name)
        hasher.combine(storageOption)
        hasher.combine(creationDate)
        hasher.combine(encryptedName)
    }

    /// Removes a migrated album's drained source directory, but ONLY when it holds no
    /// regular files — so a ciphertext the migration plan never enumerated (an orphaned
    /// or partially-written file) is preserved rather than silently destroyed. A
    /// not-fully-drained directory is left in place (the album simply remains
    /// discoverable in its source storage). Returns whether the directory is now gone.
    ///
    /// The delete goes through `NSFileCoordinator` with `.forDeleting`, and the
    /// directory is checked again for regular files inside the coordinated block. In
    /// iCloud Drive another device (one still on 2.10.0, say) can save into the album
    /// right up to the delete; the coordinated re-check keeps a file that arrived
    /// after the first check, rather than racing the directory delete against it.
    @discardableResult
    public static func removeDrainedSourceDirectory(at baseURL: URL) -> Bool {
        removeDrainedSourceDirectory(at: baseURL, beforeCoordinatedDelete: nil)
    }

    /// `beforeCoordinatedDelete` runs after the uncoordinated check and before the
    /// coordinated one, so tests can land a file in that window.
    @discardableResult
    static func removeDrainedSourceDirectory(at baseURL: URL,
                                             beforeCoordinatedDelete: (() -> Void)?) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: baseURL.path) else { return true }
        if let leftover = firstRegularFile(in: baseURL) {
            printDebug("removeDrainedSourceDirectory KEPT \(baseURL.lastPathComponent) — leftover file \(leftover.lastPathComponent)")
            return false
        }
        beforeCoordinatedDelete?()

        var removed = false
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: baseURL,
                                                         options: .forDeleting,
                                                         error: &coordinationError) { url in
            guard fileManager.fileExists(atPath: url.path) else {
                removed = true
                return
            }
            if let leftover = firstRegularFile(in: url) {
                printDebug("removeDrainedSourceDirectory KEPT \(url.lastPathComponent) — file arrived before the delete: \(leftover.lastPathComponent)")
                return
            }
            do {
                try fileManager.removeItem(at: url)
                removed = true
            } catch {
                printDebug("removeDrainedSourceDirectory could not remove \(url.lastPathComponent): \(error)")
            }
        }
        if let coordinationError {
            printDebug("removeDrainedSourceDirectory coordination failed for \(baseURL.lastPathComponent): \(coordinationError)")
            return false
        }
        return removed
    }

    private static func firstRegularFile(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false {
                return url
            }
        }
        return nil
    }

    // MARK: - Encrypt Album Name
    public var encryptedPathComponent: String {
        if let encryptedName = encryptedName {
            return encryptedName
        }
        guard let streamEnc = Sodium().secretStream.xchacha20poly1305.initPush(secretKey: key.keyBytes) else {
            debugPrint("Could not create stream with key")
            return name
        }

        let nameBytes = Array(name.utf8)

        if let encryptedMessage = streamEnc.push(message: nameBytes, tag: .FINAL) {
            var combinedData = Data(streamEnc.header()) // Add the header (24 bytes)
            combinedData.append(contentsOf: encryptedMessage)

            let finalComponent = "Album_" + combinedData.base64EncodedString().replacingOccurrences(of: "/", with: "_")
            return finalComponent
        } else {
            return name
        }
    }

    // MARK: - Decrypt Album Name

    /// The album's real name, or nil when this key did not encrypt it.
    ///
    /// The lossy sibling below reports failure by handing back its own input, which
    /// cannot be used as proof of anything: "the key was wrong" and "the name decrypted
    /// to itself" are the same value. Key resolution needs to tell those apart, and the
    /// secretstream pull is authenticated, so nil here carries the same weight as a
    /// failed first-block probe on a file.
    ///
    /// A name without the `Album_` prefix is not ciphertext at all and yields nil — no
    /// key encrypted it, so no key can be proven by it.
    public static func decryptedAlbumName(_ encryptedName: String, key: PrivateKey) -> String? {
        guard encryptedName.starts(with: "Album_") else {
            return nil
        }

        let sodium = Sodium()

        let base64String = encryptedName
            .replacingOccurrences(of: "Album_", with: "")
            .replacingOccurrences(of: "_", with: "/")

        guard let encryptedData = Data(base64Encoded: base64String) else {
            debugPrint("Could not decode base64 string for album with name: \(encryptedName)")
            return nil
        }

        let headerBytesCount = SecretStream.XChaCha20Poly1305.HeaderBytes

        guard encryptedData.count > headerBytesCount else {
            debugPrint("Not enough bytes to extract header: \(encryptedData.count) bytes found, but need at least \(headerBytesCount + 1)")
            return nil
        }

        let header = Array(encryptedData.prefix(headerBytesCount))

        let messageBytes = Array(encryptedData.dropFirst(headerBytesCount))

        guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(secretKey: key.keyBytes, header: header) else {
            debugPrint("Could not create stream with key for album with name: \(encryptedName)")
            return nil
        }

        guard let (decryptedMessage, _) = streamDec.pull(cipherText: messageBytes) else {
            debugPrint("Could not decrypt message for album with name: \(encryptedName)")
            return nil
        }

        return String(bytes: decryptedMessage, encoding: .utf8)
    }

    /// The album's name for display, falling back to the ciphertext when this key
    /// cannot open it. Kept because callers rely on getting *something* renderable
    /// back; anything deciding which key to use wants `decryptedAlbumName` instead.
    public static func decryptAlbumName(_ encryptedName: String, key: PrivateKey) -> String {
        decryptedAlbumName(encryptedName, key: key) ?? encryptedName
    }
}

extension Album: DebugPrintable {}

/// An album whose encryption key is not on this device. Carries enough metadata
/// to render a locked placeholder in the grid without exposing any decrypted
/// content or requiring a `PrivateKey`.
public struct LockedAlbumPlaceholder: Identifiable, Hashable {
    public let encryptedDirectoryName: String
    public let storageOption: StorageType
    public let creationDate: Date
    /// The key the album says it needs, when anything on disk names one. Nil
    /// means unknown, not that no key is needed.
    public let requiredKey: RequiredKeyIdentity?
    /// True when the album's media was sampled and no key on this device opened
    /// any of it. False also covers "not checked yet" and "nothing to check".
    public let contentsUnreadable: Bool

    public var id: String {
        "\(encryptedDirectoryName)_\(storageOption.rawValue)"
    }

    public init(encryptedDirectoryName: String,
                storageOption: StorageType,
                creationDate: Date,
                requiredKey: RequiredKeyIdentity? = nil,
                contentsUnreadable: Bool = false) {
        self.encryptedDirectoryName = encryptedDirectoryName
        self.storageOption = storageOption
        self.creationDate = creationDate
        self.requiredKey = requiredKey
        self.contentsUnreadable = contentsUnreadable
    }

    /// The locked-album alert's message. A known key always leads, since the
    /// Enter Key flow asks for that key; a probe that opened nothing adds a
    /// sentence after it, or stands alone when the key is unknown.
    public var lockedAlertMessage: String {
        let keyLine = requiredKey.map { L10n.MissingKey.albumSubtitleWithFingerprint($0.displayLabel) }
        switch (keyLine, contentsUnreadable) {
        case (let keyLine?, true):
            return "\(keyLine) \(L10n.MissingKey.albumContentsUnreadable)"
        case (let keyLine?, false):
            return keyLine
        case (nil, true):
            return L10n.MissingKey.albumContentsUnreadable
        case (nil, false):
            return L10n.MissingKey.subtitleUnknown
        }
    }

    /// Whether `key` is the key that encrypted this album's name — an
    /// authenticated decrypt of data that is always on the device, so it never
    /// waits on a download.
    public func proveKey(_ key: PrivateKey) -> KeyProofOutcome {
        guard encryptedDirectoryName.hasPrefix("Album_") else {
            return .indeterminate
        }
        return Album.decryptedAlbumName(encryptedDirectoryName, key: key) != nil ? .proved : .disproved
    }
}
