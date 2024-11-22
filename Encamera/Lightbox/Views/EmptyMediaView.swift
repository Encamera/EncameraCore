//
//  EmptyMediaView.swift
//  Encamera
//
//  Created by Alexander Freas on 22.11.24.
//

import Foundation
import UIKit

class EmptyMediaView: UIView, MediaViewProtocol {
    required init(viewModel: ImageViewingViewModel) {
        super.init(frame: .zero)
    }
    
    typealias ViewModel = ImageViewingViewModel

    func setMediaAndLoad(image: LightboxImage) {

    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
