import Foundation
import Photos
import UIKit

@MainActor
class PhotoDeletionManager: ObservableObject {
    @Published var isDeletingPhotos = false
    @Published var showPhotoAccessAlert = false
    
    func deletePhotos(assetIdentifiers: [String]) async {
        guard await checkPermissions() else {
            showPhotoAccessAlert = true
            return
        }
        
        await performDeletion(assetIdentifiers: assetIdentifiers)
    }
    
    private func checkPermissions() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized:
            return true
        case .limited, .denied, .restricted:
            return false
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return newStatus == .authorized
        @unknown default:
            return false
        }
    }
    
    private func performDeletion(assetIdentifiers: [String]) async {
        isDeletingPhotos = true
        defer { isDeletingPhotos = false }
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIdentifiers, options: nil)
        
        if assets.count > 0 {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets)
                }
                debugPrint("Successfully deleted \(assets.count) photos from Photo Library")
                
                // Track the deletion
                EventTracking.trackMediaDeleted(count: assets.count)
                
            } catch {
                debugPrint("Failed to delete photos: \(error)")
            }
        } else {
            debugPrint("No assets found to delete")
        }
    }
    
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
} 