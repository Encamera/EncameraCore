//
//  PurchasePromptView.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.24.
//

import Foundation
import UIKit
import EncameraCore

class PhotoLimitReachedView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        backgroundColor = UIColor.clear

        // Container view
        let containerView = UIView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.backgroundColor = UIColor.white
        containerView.layer.cornerRadius = 16
        addSubview(containerView)

        // Warning Icon
        let warningImageView = UIImageView()
        warningImageView.translatesAutoresizingMaskIntoConstraints = false
        warningImageView.image = UIImage(named: "Warning-Triangle") // Assuming "warningIcon" is available in assets
        warningImageView.contentMode = .scaleAspectFit
        containerView.addSubview(warningImageView)

        // Title Label
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = L10n.photoLimitReached
        titleLabel.applyFontType(.pt16, on: .lightBackground, weight: .bold)
        titleLabel.textAlignment = .center
        containerView.addSubview(titleLabel)

        // Description Label
        let descriptionLabel = UILabel()
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.text = L10n.modalUpgradeText
        descriptionLabel.applyFontType(.pt16, on: .lightBackground, weight: .regular)
        descriptionLabel.textAlignment = .center
        descriptionLabel.numberOfLines = 0
        containerView.addSubview(descriptionLabel)

        // Upgrade Button
        let upgradeButton = UIButton(type: .system)
        upgradeButton.translatesAutoresizingMaskIntoConstraints = false
        upgradeButton.setTitle(L10n.upgradeToPremium, for: .normal)
        upgradeButton.backgroundColor = SurfaceType.primaryButton.foregroundSecondaryUIColor
        upgradeButton.applyFontType(.pt16, on: .primaryButton, weight: .bold)
        upgradeButton.layer.cornerRadius = 8
        containerView.addSubview(upgradeButton)
        
        // Back Button
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setTitle(L10n.backToAlbum, for: .normal)
        backButton.setTitleColor(UIColor.systemBlue, for: .normal)
        containerView.addSubview(backButton)

        // Constraints
        NSLayoutConstraint.activate([
            // Container view constraints
            containerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            // Warning icon constraints
            warningImageView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24),
            warningImageView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            warningImageView.heightAnchor.constraint(equalToConstant: 48),
            warningImageView.widthAnchor.constraint(equalToConstant: 48),

            // Title label constraints
            titleLabel.topAnchor.constraint(equalTo: warningImageView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            // Description label constraints
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            descriptionLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            descriptionLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            // Upgrade button constraints
            upgradeButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 24),
            upgradeButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            upgradeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            upgradeButton.heightAnchor.constraint(equalToConstant: 44),

            // Back button constraints
            backButton.topAnchor.constraint(equalTo: upgradeButton.bottomAnchor, constant: 16),
            backButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            backButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            backButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -24)
        ])
    }
}
