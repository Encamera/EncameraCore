import SwiftUI
import PhotosUI;

struct PhotoPicker: UIViewControllerRepresentable {
    var selectedItems: ([PHPickerResult]) -> ()
    var filter: PHPickerFilter = .images // Use .videos for videos, or .any(of: [.images, .videos]) for both

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0 // 0 for unlimited selection, set to 1 or any number for specific limits
        config.filter = filter

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

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
            picker.dismiss(animated: true)
        }
    }
}
