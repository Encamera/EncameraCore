//
//  iCloudFileStatusUtil.swift
//  EncameraCore
//
//  Created for iCloud file status detection
//

import Foundation
import Combine

/// Represents the download status of an iCloud file
public enum iCloudFileDownloadState: Equatable {
    case notUbiquitous          // File is not an iCloud file
    case current                 // File is fully downloaded and current
    case notDownloaded           // File exists in iCloud but not downloaded locally
    case downloading(progress: Double)  // File is currently downloading
    case downloadFailed(error: Error?)  // Download was attempted but failed
    
    public static func == (lhs: iCloudFileDownloadState, rhs: iCloudFileDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.notUbiquitous, .notUbiquitous),
             (.current, .current),
             (.notDownloaded, .notDownloaded):
            return true
        case (.downloading(let p1), .downloading(let p2)):
            return p1 == p2
        case (.downloadFailed, .downloadFailed):
            return true
        default:
            return false
        }
    }
}

/// Comprehensive status information for an iCloud file
public struct iCloudFileStatus {
    /// Whether this is a ubiquitous (iCloud) item
    public let isUbiquitousItem: Bool
    
    /// The current download state
    public let downloadState: iCloudFileDownloadState
    
    /// Whether a download has been requested
    public let downloadRequested: Bool
    
    /// Whether the file is currently being downloaded
    public let isDownloading: Bool
    
    /// Download progress percentage (0-100)
    public let downloadProgress: Double?
    
    /// Any error that occurred during download
    public let downloadingError: Error?
    
    /// The filename for display purposes
    public let filename: String
    
    /// Whether the file needs to be downloaded before it can be accessed
    public var needsDownload: Bool {
        switch downloadState {
        case .notDownloaded, .downloadFailed:
            return true
        case .downloading:
            return true
        default:
            return false
        }
    }
}

/// Utility for checking iCloud file status
public struct iCloudFileStatusUtil {
    
    /// Resource keys needed for comprehensive iCloud status check
    private static let resourceKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemDownloadRequestedKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingErrorKey,
        .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey
    ]
    
    /// Gets comprehensive iCloud status for a file URL
    /// - Parameter url: The file URL to check
    /// - Returns: An iCloudFileStatus struct with all available information
    public static func getStatus(for url: URL) -> iCloudFileStatus {
        let filename = url.lastPathComponent
        
        do {
            let resourceValues = try url.resourceValues(forKeys: resourceKeys)
            
            let isUbiquitous = resourceValues.isUbiquitousItem ?? false
            let downloadRequested = resourceValues.ubiquitousItemDownloadRequested ?? false
            let isDownloading = resourceValues.ubiquitousItemIsDownloading ?? false
            let downloadingError = resourceValues.ubiquitousItemDownloadingError
            
            let downloadState: iCloudFileDownloadState
            
            if !isUbiquitous {
                downloadState = .notUbiquitous
            } else if let error = downloadingError {
                downloadState = .downloadFailed(error: error)
            } else if let status = resourceValues.ubiquitousItemDownloadingStatus {
                switch status {
                case .current:
                    downloadState = .current
                case .notDownloaded:
                    if isDownloading {
                        downloadState = .downloading(progress: 0)
                    } else {
                        downloadState = .notDownloaded
                    }
                default:
                    downloadState = .current
                }
            } else {
                // No downloadingStatus available from iCloud metadata yet.
                // This commonly occurs for files that were just created locally in
                // the iCloud container — iCloud hasn't finished cataloging them.
                // Use ubiquitousItemIsUploaded to distinguish: if false, the file
                // was created locally and hasn't been synced yet (data IS on disk).
                // If true (or unknown), the file has been uploaded before and may be
                // evicted — we must NOT assume local data is present based on fileSize,
                // because evicted files report their full cloud size.
                let isUploaded = resourceValues.ubiquitousItemIsUploaded ?? true
                if !isUploaded {
                    downloadState = .current
                } else {
                    downloadState = .notDownloaded
                }
            }
            
            return iCloudFileStatus(
                isUbiquitousItem: isUbiquitous,
                downloadState: downloadState,
                downloadRequested: downloadRequested,
                isDownloading: isDownloading,
                downloadProgress: nil,
                downloadingError: downloadingError,
                filename: filename
            )
            
        } catch {
            return iCloudFileStatus(
                isUbiquitousItem: false,
                downloadState: .notUbiquitous,
                downloadRequested: false,
                isDownloading: false,
                downloadProgress: nil,
                downloadingError: error,
                filename: filename
            )
        }
    }
    
    /// Checks if a file needs to be downloaded from iCloud
    /// - Parameter url: The file URL to check
    /// - Returns: True if the file is in iCloud and not downloaded locally
    public static func needsDownload(url: URL) -> Bool {
        let status = getStatus(for: url)
        return status.needsDownload
    }
    
    /// Attempts to start downloading a file from iCloud
    /// - Parameter url: The file URL to download
    /// - Throws: If the download cannot be started
    public static func startDownload(for url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
    
    /// Gets a user-friendly error message for iCloud download issues
    /// - Parameters:
    ///   - status: The current file status
    /// - Returns: A localized error message suitable for display to users
    public static func userFriendlyErrorMessage(for status: iCloudFileStatus) -> String {
        switch status.downloadState {
        case .notDownloaded:
            return L10n.ICloudError.fileNotDownloaded
        case .downloadFailed(let error):
            if let error = error {
                return L10n.ICloudError.downloadFailed(status.filename, error.localizedDescription)
            }
            return L10n.ICloudError.downloadFailedGeneric(status.filename)
        case .downloading:
            return L10n.ICloudError.downloadInProgress(status.filename)
        default:
            return ""
        }
    }
}

// MARK: - Directory Sync Status

/// Aggregate status of iCloud sync for a directory
public enum iCloudDirectorySyncState: Equatable {
    case allSynced                    // All files are downloaded
    case syncing(downloaded: Int, total: Int, progress: Double)  // Files are being downloaded
    case pendingDownload(count: Int)  // Files need to be downloaded but aren't downloading
    case noFiles                      // No files in directory
    case notICloud                    // Not an iCloud directory
}

/// Published status for a directory's iCloud sync state
public struct iCloudDirectorySyncStatus {
    public let state: iCloudDirectorySyncState
    public let totalFiles: Int
    public let downloadedFiles: Int
    public let downloadingFiles: Int
    public let pendingFiles: Int
    public let overallProgress: Double  // 0.0 to 1.0
    
    public init(
        state: iCloudDirectorySyncState,
        totalFiles: Int,
        downloadedFiles: Int,
        downloadingFiles: Int,
        pendingFiles: Int,
        overallProgress: Double
    ) {
        self.state = state
        self.totalFiles = totalFiles
        self.downloadedFiles = downloadedFiles
        self.downloadingFiles = downloadingFiles
        self.pendingFiles = pendingFiles
        self.overallProgress = overallProgress
    }
}
