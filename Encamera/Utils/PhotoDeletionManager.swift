import Foundation
import Photos
import UIKit

@MainActor
class PhotoDeletionManager: ObservableObject {
    @Published var isDeletingPhotos = false
    @Published var showPhotoAccessAlert = false
    @Published var showLimitedAccessInfo = false
    
    func deletePhotos(assetIdentifiers: [String]) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized:
            // Full access - proceed with deletion
            await performDeletion(assetIdentifiers: assetIdentifiers)
            
        case .limited:
            // Limited access - show info alert but still proceed with deletion
            showLimitedAccessInfo = true
            await performDeletion(assetIdentifiers: assetIdentifiers)
            
        case .denied, .restricted:
            // No access - show access alert and don't proceed
            showPhotoAccessAlert = true
            return
            
        case .notDetermined:
            // Request permission first
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if newStatus == .authorized || newStatus == .limited {
                await deletePhotos(assetIdentifiers: assetIdentifiers) // Recursive call with new status
            } else {
                showPhotoAccessAlert = true
            }
            
        @unknown default:
            showPhotoAccessAlert = true
            return
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