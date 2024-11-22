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
    associatedtype HostingView: UIView
    init(viewModel: ViewModel)
    
    func setMediaAndLoad(image: LightboxImage)

    var image: UIImage? { get }
    var viewModel: ViewModel? { get }
    var hostingView: HostingView { get }
    var errorLabel: UILabel { get }

    var activityIndicator: UIActivityIndicatorView { get }
}

extension MediaViewProtocol {

    var errorLabel: UILabel {
        UILabel()
    }
    var activityIndicator: UIActivityIndicatorView { return UIActivityIndicatorView(style: .large)
    }

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


    func setupViews() {
        // Setup live photo view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        // Setup activity indicator
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        addSubview(activityIndicator)

        // Setup error label
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        addSubview(errorLabel)

        // Layout Constraints
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)
        ])

        // Initially hide all components except the activity indicator
        hostingView.isHidden = true
        errorLabel.isHidden = true
        activityIndicator.startAnimating()
    }
}
