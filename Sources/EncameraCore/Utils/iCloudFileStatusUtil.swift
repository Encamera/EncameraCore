//
//  iCloudFileStatusUtil.swift
//  EncameraCore
//
//  Created for iCloud file status detection
//

import Foundation

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
    
    /// Human-readable description of the current status
    public var statusDescription: String {
        switch downloadState {
        case .notUbiquitous:
            return L10n.ICloudStatus.notICloudFile
        case .current:
            return L10n.ICloudStatus.downloaded
        case .notDownloaded:
            return L10n.ICloudStatus.notDownloaded
        case .downloading(let progress):
            return L10n.ICloudStatus.downloading(Int(progress))
        case .downloadFailed(let error):
            if let error = error {
                return L10n.ICloudStatus.downloadFailed(error.localizedDescription)
            }
            return L10n.ICloudStatus.downloadFailedUnknown
        }
    }
    
    /// Whether the file needs to be downloaded before it can be accessed
    public var needsDownload: Bool {
        switch downloadState {
        case .notDownloaded, .downloadFailed:
            return true
        case .downloading:
            return true // Still needs to complete download
        default:
            return false
        }
    }
    
    /// Whether we can attempt to trigger a download
    public var canAttemptDownload: Bool {
        switch downloadState {
        case .notDownloaded, .downloadFailed:
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
        .ubiquitousItemDownloadingErrorKey
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
            
            // Determine download state
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
                        // Try to get progress - use NSMetadataQuery for more accurate progress
                        downloadState = .downloading(progress: 0)
                    } else {
                        downloadState = .notDownloaded
                    }
                default:
                    // .downloaded but not .current means it's downloaded but may need update
                    downloadState = .current
                }
            } else {
                // No status available, assume not downloaded if ubiquitous
                downloadState = .notDownloaded
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
            // If we can't get resource values, assume it's not a ubiquitous item
            // but this could also indicate the file doesn't exist
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
    
    /// Checks if a file is a ubiquitous (iCloud) item
    /// - Parameter url: The file URL to check
    /// - Returns: True if the file is an iCloud item
    public static func isUbiquitousItem(url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
            return resourceValues.isUbiquitousItem ?? false
        } catch {
            return false
        }
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

