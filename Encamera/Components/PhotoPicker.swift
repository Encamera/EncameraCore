import SwiftUI
import PhotosUI
import UIKit

// MARK: - SwiftUI Native PhotosPicker (iOS 16+)
// This is the new SwiftUI-native picker that's simpler to use
// Note: Does NOT support swipe-to-select gesture
@available(iOS 16.0, *)
struct ModernPhotoPicker: View {
    @Binding var selectedItems: [PhotosPickerItem]
    @Binding var selectedPhotos: [UIImage]
    var maxSelectionCount: Int? = nil
    var filter: PHPickerFilter = .images
    
    var body: some View {
        PhotosPicker(
            selection: $selectedItems,
            maxSelectionCount: maxSelectionCount,
            matching: filter,
            photoLibrary: .shared()
        ) {
            Label("Select Photos", systemImage: "photo.on.rectangle.angled")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.blue)
        }
        .onChange(of: selectedItems) { _, newItems in
            Task {
                selectedPhotos.removeAll()
                
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedPhotos.append(image)
                    }
                }
            }
        }
    }
}

// MARK: - PHPickerViewController Wrapper (Compatible with existing code)
// This maintains compatibility with your existing PHPickerResult-based code
struct PhotoPicker: UIViewControllerRepresentable {
    var selectedItems: ([PHPickerResult]) -> ()
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
            parent.selectedItems(results)
            picker.dismiss(animated: true, completion: nil)
        }
    }
}

// MARK: - Alternative Solutions for Swipe Selection
// If swipe-to-select is critical for your UX, consider:
//
// 1. Custom Photo Picker using PhotoKit
//    - Requires photo library permission
//    - More complex implementation
//    - Full control over gestures and UI
//
// 2. Third-party libraries (though most also lack swipe selection)
//
// 3. File feedback to Apple requesting this feature
//    - Many developers want this functionality
//
// 4. For iOS 17+: Embedded picker with continuous selection
//    - Use .photosPickerStyle(.inline)
//    - Still doesn't support swipe, but provides live updates
