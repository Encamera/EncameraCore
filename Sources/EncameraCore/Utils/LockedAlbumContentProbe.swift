//
//  LockedAlbumContentProbe.swift
//  EncameraCore
//
//  Tests whether a held key opens the media of an album whose name key is absent.
//

import Foundation

/// Whether any key on this device opens the media inside a directory album whose
/// encrypted name no held key opens.
///
/// The name and the contents need not share a key. Up to 2.9.x every directory
/// album opened under the current key whatever key had encrypted its name, so an
/// album named under key K1 holds everything imported into it on a device whose
/// key was K2. That media is readable here even though the name is not.
///
/// The probe reads a bounded sample: at most `maxFilesSampled` files, each one
/// prologue plus one ciphertext block, with the file's stamp tried first, then the
/// current key, then the rest of the library (`KeyDiscovery.discoverKeyOutcome`).
public enum LockedAlbumContentProbe {

    /// Upper bound on files read per album.
    public static let maxFilesSampled = 8

    public enum Outcome: Equatable {
        /// A held key opened at least one sampled file. `key` is the key that
        /// opened the most of them. `lockedFileNames` are sampled files no held
        /// key opens; the grid shows those as missing-key tiles.
        case readable(key: PrivateKey, lockedFileNames: Set<String>)
        /// Files were tested and none opened with any held key.
        case noneOpened
        /// Nothing could be tested: no media, or none of it readable yet (an
        /// iCloud Drive file still downloading, or damaged bytes).
        case nothingTested
    }

    /// Probes the album directory at `albumDirectory`. Performs no writes.
    ///
    /// - Parameter onFileProbed: called once per file read, so tests can check
    ///   the sample bound.
    public static func probe(albumDirectory: URL,
                             keyManager: KeyManager,
                             storedKeys: [PrivateKey],
                             onFileProbed: ((URL) -> Void)? = nil) async -> Outcome {
        let mediaExtensions: Set<String> = [MediaType.photo.encryptedFileExtension,
                                            MediaType.video.encryptedFileExtension]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: albumDirectory,
                                                                          includingPropertiesForKeys: nil) else {
            return .nothingTested
        }
        let sample = contents
            .filter { mediaExtensions.contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maxFilesSampled)

        var openedCounts: [UUID: (key: PrivateKey, count: Int, order: Int)] = [:]
        var lockedFileNames = Set<String>()
        for url in sample {
            onFileProbed?(url)
            switch await KeyDiscovery.discoverKeyOutcome(for: url,
                                                         keyManager: keyManager,
                                                         storedKeysSnapshot: storedKeys) {
            case .resolved(let result):
                let existing = openedCounts[result.key.uuid]
                openedCounts[result.key.uuid] = (result.key,
                                                 (existing?.count ?? 0) + 1,
                                                 existing?.order ?? openedCounts.count)
            case .noKnownKey:
                lockedFileNames.insert(url.lastPathComponent)
            case .unreadable:
                continue
            }
        }

        // Most files opened wins; on a tie, the key that opened a file first, which
        // follows the discovery order (stamp, current key, library).
        if let best = openedCounts.values.max(by: { lhs, rhs in
            lhs.count != rhs.count ? lhs.count < rhs.count : lhs.order > rhs.order
        }) {
            return .readable(key: best.key, lockedFileNames: lockedFileNames)
        }
        return lockedFileNames.isEmpty ? .nothingTested : .noneOpened
    }
}

/// Probe outcomes per album directory for the life of one `AlbumManager`, so a
/// listing reads a directory's files at most once per key library.
///
/// An entry is reused only while the key library it was computed against and the
/// directory's modification date are unchanged: a new key may open what nothing
/// opened before, and an iCloud Drive file that finishes downloading changes the
/// directory.
final class LockedAlbumContentProbeCache: @unchecked Sendable {

    private struct Entry {
        let outcome: LockedAlbumContentProbe.Outcome
        let keyLibrary: Set<String>
        let directoryModified: Date?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<LockedAlbumContentProbe.Outcome, Never>] = [:]

    /// The cached outcome for `directory`, or nil when it has not been probed
    /// against `keyLibrary`.
    func outcome(for directory: URL, keyLibrary: Set<String>) -> LockedAlbumContentProbe.Outcome? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[directory.standardizedFileURL.path],
              entry.keyLibrary == keyLibrary,
              entry.directoryModified == Self.modificationDate(of: directory) else {
            return nil
        }
        return entry.outcome
    }

    /// Probes `directory` off the caller's actor, joining a probe already running
    /// for it, and caches the result. `onFinished` runs once, only for the call
    /// that started the probe.
    @discardableResult
    func probe(directory: URL,
               keyLibrary: Set<String>,
               run: @escaping @Sendable () async -> LockedAlbumContentProbe.Outcome,
               onFinished: (@Sendable (LockedAlbumContentProbe.Outcome) -> Void)? = nil) -> Task<LockedAlbumContentProbe.Outcome, Never> {
        let path = directory.standardizedFileURL.path
        let directoryModified = Self.modificationDate(of: directory)
        lock.lock()
        if let running = inFlight[path] {
            lock.unlock()
            return running
        }
        let task = Task.detached(priority: .utility) { [weak self] () -> LockedAlbumContentProbe.Outcome in
            let outcome = await run()
            self?.finish(path: path,
                         entry: Entry(outcome: outcome, keyLibrary: keyLibrary, directoryModified: directoryModified))
            onFinished?(outcome)
            return outcome
        }
        inFlight[path] = task
        lock.unlock()
        return task
    }

    /// Waits for every probe running now.
    func waitForProbes() async {
        let running: [Task<LockedAlbumContentProbe.Outcome, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            return Array(inFlight.values)
        }()
        for task in running {
            _ = await task.value
        }
    }

    private static func modificationDate(of directory: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
    }

    private func finish(path: String, entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = entry
        inFlight[path] = nil
    }
}
