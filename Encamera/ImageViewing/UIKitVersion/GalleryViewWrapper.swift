//
//  GalleryViewWrapper.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//

import Foundation
import SwiftUI

struct GalleryViewWrapper: UIViewControllerRepresentable {
    typealias UIViewControllerType = GalleryViewController

    let viewModel: GalleryHorizontalCollectionViewModel

    func makeUIViewController(context: Context) -> GalleryViewController {
        return GalleryViewController(viewModel: viewModel)
    }

    func updateUIViewController(_ uiViewController: GalleryViewController, context: Context) {
        // Update the view controller if needed
    }
}
