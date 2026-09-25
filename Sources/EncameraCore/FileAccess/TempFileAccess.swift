import Foundation

public class TempFileAccess: DebugPrintable {

    @MainActor public static func cleanupTemporaryFiles() {
        printDebug("TempFileAccess.cleanupTemporaryFiles() called")
        printDebug("BackgroundTaskManager.shared.isProcessing: \(BackgroundTaskManager.shared.isProcessing)")
        
        if !BackgroundTaskManager.shared.isProcessing {
            printDebug("isProcessing is false - proceeding with cleanup")
            deleteDirectory(at: URL.tempMediaDirectory)
            deleteDirectory(at: URL.tempExportDirectory)
            deleteStaleFiles(in: CKDatabaseAdapter.assetSnapshotDirectory, olderThan: 60)
            createDirectoryIfNeeded(at: URL.tempMediaDirectory)
        } else {
            printDebug("isProcessing is true - skipping cleanup")
        }
    }

    public static func cleanupRecordings() {
        deleteDirectory(at: URL.tempRecordingDirectory)
        createDirectoryIfNeeded(at: URL.tempRecordingDirectory)
    }
    
    private static func createDirectoryIfNeeded(at url: URL) {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                printDebug("Created directory at \(url.path)")
            }
        } catch {
            printDebug("ERROR: Could not create directory at \(url.path): \(error)")
        }
    }

    /// Deletes only those files in `directory` whose modification date is more
    /// than `age` seconds in the past. Recently-written files are left alone so
    /// an in-flight consumer can still read them.
    private static func deleteStaleFiles(in directory: URL, olderThan age: TimeInterval) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            printDebug("deleteStaleFiles: directory does not exist at \(directory.path)")
            return
        }
        do {
            let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            let now = Date()
            var deleted = 0
            var skipped = 0
            for fileURL in contents {
                let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                if let modDate = values.contentModificationDate, now.timeIntervalSince(modDate) > age {
                    try fm.removeItem(at: fileURL)
                    deleted += 1
                } else {
                    skipped += 1
                }
            }
            printDebug("deleteStaleFiles: \(directory.lastPathComponent) — deleted \(deleted), skipped \(skipped) (threshold \(age)s)")
        } catch {
            printDebug("ERROR: deleteStaleFiles failed for \(directory.path): \(error)")
        }
    }

    private static func deleteDirectory(at url: URL) {
        printDebug("deleteDirectory called for: \(url.path)")
        
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                printDebug("Directory exists with \(contents.count) items")
                
                if contents.count > 0 && contents.count <= 10 {
                    printDebug("Directory contents:")
                    for item in contents {
                        printDebug("  - \(item.lastPathComponent)")
                    }
                } else if contents.count > 10 {
                    printDebug("Directory contains \(contents.count) items (showing first 10):")
                    for item in contents.prefix(10) {
                        printDebug("  - \(item.lastPathComponent)")
                    }
                }
                
                let subdirs = contents.filter { url in
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    return isDir.boolValue
                }
                if !subdirs.isEmpty {
                    printDebug("Found \(subdirs.count) subdirectories")
                }
                
                printDebug("Deleting directory at \(url.path)")
                try FileManager.default.removeItem(at: url)
                printDebug("Successfully deleted directory at \(url.path)")
            } else {
                printDebug("Directory does not exist at \(url.path), nothing to delete")
            }
        } catch let error {
            printDebug("ERROR: Could not delete directory: \(error)")
            printDebug("Error type: \(type(of: error))")
            if let nsError = error as NSError? {
                printDebug("NSError domain: \(nsError.domain), code: \(nsError.code)")
            }
        }
    }

}
