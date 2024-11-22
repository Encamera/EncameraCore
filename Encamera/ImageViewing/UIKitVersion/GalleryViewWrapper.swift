//
//  GalleryViewWrapper.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//

import Foundation
import SwiftUI

struct GalleryViewWrapper: UIViewControllerRepresentable {
    typealias UIViewControllerType = LightboxController

    let viewModel: GalleryHorizontalCollectionViewModel

    func makeUIViewController(context: Context) -> LightboxController {
        let startIndex = (viewModel.initialMedia != nil) ? Int(viewModel.media.firstIndex(of: viewModel.initialMedia!) ?? 0) : 0
        return LightboxController(images: viewModel.media, startIndex: startIndex, fileAccess: viewModel.fileAccess)
    }

    func updateUIViewController(_ uiViewController: LightboxController, context: Context) {
        // Update the view controller if needed
    }
}
