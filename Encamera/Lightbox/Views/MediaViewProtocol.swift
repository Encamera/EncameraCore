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
}
