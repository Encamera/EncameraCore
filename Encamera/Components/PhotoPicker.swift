import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PHPickerViewController Wrapper (Standard iOS Photo Picker)
// This is the standard system photo picker that runs in a separate process
// Use PhotoPickerWrapper instead, which automatically selects between this
// and CustomPhotoPicker based on photo library permissions
struct PhotoPicker: UIViewControllerRepresentable {
    var selectedItems: ([MediaSelectionResult]) -> ()
    var filter: PHPickerFilter = .images
    var selectionLimit: Int = 0 // 0 for unlimited

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        
        // IMPORTANT: Neither PHPickerViewController nor the native PhotosPicker
        // support swipe-to-select gesture. Users must tap each photo individually.
        // This is an iOS limitation, not a bug in your implementation.
        
        config.selectionLimit = selectionLimit
        config.filter = filter
        
        // Shows numbers on selected items indicating selection order
        // This helps users understand their selection sequence
        config.selection = .ordered
        
        // Improves performance by avoiding transcoding
        config.preferredAssetRepresentationMode = .current
        
        // Additional options available in iOS 16+:
        // - config.preselectedAssetIdentifiers = [] // Pre-select certain photos
        // - config.mode = .default // or .compact for single row
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        
        // Note: The picker runs in a separate process for privacy
        // This provides better security but limits customization options
        
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // Update configuration if needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: PhotoPicker

        init(_ parent: PhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Convert PHPickerResult to MediaSelectionResult
            let mediaResults = results.map { MediaSelectionResult.phPickerResult($0) }
            parent.selectedItems(mediaResults)
            picker.dismiss(animated: true, completion: nil)
        }
    }
}

// MARK: - Photo Picker Architecture in Encamera
//
// Encamera now has THREE photo picker implementations:
//
// 1. PhotoPicker (this file) - Standard PHPickerViewController
//    - Runs in separate process for privacy
//    - Limited UI customization
//    - No swipe-to-select support
//
// 2. CustomPhotoPicker - Full PhotoKit implementation
//    - Requires full photo library access
//    - Supports swipe-to-select gesture
//    - Shows video duration indicators
//    - Numbers show selection order
//
// 3. PhotoPickerWrapper - Smart wrapper that chooses the best picker
//    - Automatically uses CustomPhotoPicker when full access is granted
//    - Falls back to PhotoPicker for limited access
//    - Prompts users to upgrade permissions for better experience
//
// USAGE: Always use PhotoPickerWrapper in your views for the best experience!
