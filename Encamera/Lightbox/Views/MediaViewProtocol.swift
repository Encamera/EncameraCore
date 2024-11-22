//
//  MediaViewProtocol.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//

import Foundation
import UIKit

protocol MediaViewProtocol: UIView {
    associatedtype ViewModel: MediaViewModelProtocol
    init(viewModel: ViewModel)
    
    func setMediaAndLoad(image: LightboxImage)

    var image: UIImage? { get }
    var viewModel: ViewModel? { get }
}

extension MediaViewProtocol {
    var image: UIImage? {
        if let imageData = viewModel?.sourceMedia.imageData {
            return UIImage(data: imageData)
        } else {
            return nil
        }
    }

    func setMediaAndLoad(image: LightboxImage) {
        viewModel?.decryptAndSet()
    }
}
