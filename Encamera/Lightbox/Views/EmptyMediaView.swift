//
//  EmptyMediaView.swift
//  Encamera
//
//  Created by Alexander Freas on 22.11.24.
//

import Foundation
import UIKit

class EmptyMediaView: UIView, MediaViewProtocol {
    var hostingView: UIView = UIView()
    var activityIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .large)
    var errorLabel: UILabel = UILabel()

    typealias HostingView = UIView

    var viewModel: ImageViewingViewModel?

    required init(viewModel: ImageViewingViewModel) {
        super.init(frame: .zero)
    }
    
    typealias ViewModel = ImageViewingViewModel

    func setMediaAndLoad(image: LightboxImage) {

    }
    func reset() {
        
    }
    init() {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
