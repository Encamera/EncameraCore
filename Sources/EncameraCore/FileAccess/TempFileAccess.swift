import Foundation

public class TempFileAccess: DebugPrintable {

    @MainActor public static func cleanupTemporaryFiles() {
        printDebug("TempFileAccess.cleanupTemporaryFiles() called")
        printDebug("BackgroundTaskManager.shared.isProcessing: \(BackgroundTaskManager.shared.isProcessing)")
        
        if !BackgroundTaskManager.shared.isProcessing {
            printDebug("isProcessing is false - proceeding with cleanup")
            deleteDirectory(at: URL.tempMediaDirectory)
            // Recreate the temp directory after cleanup to ensure it exists for future operations
            createDirectoryIfNeeded(at: URL.tempMediaDirectory)
        } else {
            printDebug("isProcessing is true - skipping cleanup")
        }
    }

    public static func cleanupRecordings() {
        deleteDirectory(at: URL.tempRecordingDirectory)
        // Recreate the temp recording directory after cleanup
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

    private static func deleteDirectory(at url: URL) {
        printDebug("deleteDirectory called for: \(url.path)")
        
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                // List contents before deletion
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
                
                // Check if any subdirectories exist
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
