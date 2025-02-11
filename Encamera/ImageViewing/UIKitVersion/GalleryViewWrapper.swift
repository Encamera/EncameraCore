import Foundation
import SwiftUI

struct GalleryViewWrapper: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIViewController

    @EnvironmentObject var appModalStateModel: AppModalStateModel
    let viewModel: GalleryHorizontalCollectionViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIViewControllerType {
        let startIndex = (viewModel.initialMedia != nil) ? Int(viewModel.media.firstIndex(of: viewModel.initialMedia!) ?? 0) : 0
        let controller = LightboxController(images: viewModel.media,
                                            startIndex: startIndex,
                                            fileAccess: viewModel.fileAccess,
                                            purchasePermissionsManager: viewModel.purchasedPermissions,
                                            albumManager: viewModel.albumManager,
                                            album: viewModel.album,
                                            purchaseButtonPressed: viewModel.purchaseButtonPressed,
                                            reviewAlertActionPressed: viewModel.reviewAlertActionPressed)

        controller.dismissalDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {}

    class Coordinator: NSObject, LightboxControllerDismissalDelegate {
        var parent: GalleryViewWrapper

        init(_ parent: GalleryViewWrapper) {
            self.parent = parent
        }

        func lightboxControllerWillDismiss(_ controller: LightboxController) {
            parent.appModalStateModel.currentModal = nil
        }
    }
}
