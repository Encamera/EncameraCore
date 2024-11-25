//
//  GalleryViewWrapper.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//

import Foundation
import SwiftUI

struct GalleryViewWrapper: UIViewControllerRepresentable {

    
    typealias UIViewControllerType = UIViewController

    let viewModel: GalleryHorizontalCollectionViewModel

    func makeUIViewController(context: Context) -> UIViewControllerType {
        let startIndex = (viewModel.initialMedia != nil) ? Int(viewModel.media.firstIndex(of: viewModel.initialMedia!) ?? 0) : 0
        return LightboxController(images: viewModel.media,
                                  startIndex: startIndex,
                                  fileAccess: viewModel.fileAccess,
                                  purchasePermissionsManager: viewModel.purchasedPermissions, purchaseButtonPressed: viewModel.purchaseButtonPressed)
    }

    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {
    }
}
