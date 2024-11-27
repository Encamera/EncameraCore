import Foundation
import UIKit
import EncameraCore

class PhotoLimitReachedView: UIView {

    private var upgradeAction: (() -> Void)?

    init(frame: CGRect, upgradeAction: @escaping () -> Void) {
        self.upgradeAction = upgradeAction
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
        upgradeButton.addTarget(self, action: #selector(upgradeButtonTapped), for: .touchUpInside)
        containerView.addSubview(upgradeButton)

        // Define constants for reused values
        let sidePadding: CGFloat = 16
        let containerPadding: CGFloat = 24
        let warningImageSize: CGFloat = 48
        let buttonHeight: CGFloat = 54
        let titleToWarningSpacing: CGFloat = 16
        let descriptionToTitleSpacing: CGFloat = 8
        let buttonToDescriptionSpacing: CGFloat = 24

        // Constraints
        NSLayoutConstraint.activate([
            // Container view constraints
            containerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: containerPadding),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -containerPadding),

            // Warning icon constraints
            warningImageView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: containerPadding),
            warningImageView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            warningImageView.heightAnchor.constraint(equalToConstant: warningImageSize),
            warningImageView.widthAnchor.constraint(equalToConstant: warningImageSize),

            // Title label constraints
            titleLabel.topAnchor.constraint(equalTo: warningImageView.bottomAnchor, constant: titleToWarningSpacing),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: sidePadding),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -sidePadding),

            // Description label constraints
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: descriptionToTitleSpacing),
            descriptionLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: sidePadding),
            descriptionLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -sidePadding),

            // Upgrade button constraints
            upgradeButton.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: buttonToDescriptionSpacing),
            upgradeButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: sidePadding),
            upgradeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -sidePadding),
            upgradeButton.heightAnchor.constraint(equalToConstant: buttonHeight),
            upgradeButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -containerPadding)
        ])
    }

    @objc private func upgradeButtonTapped() {
        upgradeAction?()
    }
}
