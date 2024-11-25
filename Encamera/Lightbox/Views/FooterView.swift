import UIKit

protocol FooterViewDelegate: AnyObject {
    @MainActor
    func footerView(_ footerView: FooterView, didPressDeleteButton deleteButton: UIButton)
    @MainActor
    func footerView(_ footerView: FooterView, didPressShareButton shareButton: UIButton)
    @MainActor
    func footerView(_ footerView: FooterView, didPressInfoButton infoButton: UIButton)
}

open class FooterView: UIView {
    open fileprivate(set) lazy var deleteButton: UIButton = { [unowned self] in
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "trash"), for: .normal)
        button.tintColor = .systemRed
        button.backgroundColor = UIColor(white: 0.0, alpha: 0.1)
        button.layer.cornerRadius = 25  // Make it round assuming width and height are equal
        button.clipsToBounds = true
        button.addTarget(self, action: #selector(deleteButtonDidPress(_:)), for: .touchUpInside)
        button.isHidden = !LightboxConfig.DeleteButton.enabled
        button.translatesAutoresizingMaskIntoConstraints = false

        return button
    }()

    open fileprivate(set) lazy var shareButton: UIButton = { [unowned self] in
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        button.tintColor = .systemBlue
        button.backgroundColor = UIColor(white: 0.0, alpha: 0.1)
        button.layer.cornerRadius = 25  // Make it round assuming width and height are equal
        button.clipsToBounds = true
        button.addTarget(self, action: #selector(shareButtonDidPress(_:)), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        return button
    }()

    open fileprivate(set) lazy var infoButton: UIButton = { [unowned self] in
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "info.circle"), for: .normal)
        button.tintColor = .systemGray
        button.backgroundColor = UIColor(white: 0.0, alpha: 0.1)
        button.layer.cornerRadius = 25  // Make it round assuming width and height are equal
        button.clipsToBounds = true
        button.addTarget(self, action: #selector(infoButtonDidPress(_:)), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        return button
    }()

    weak var delegate: (any FooterViewDelegate)?

    // MARK: - Initializers

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)
        blurEffectView.frame = bounds
        blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(blurEffectView, at: 0)  // Ultra-thin frosted background

        [deleteButton, shareButton, infoButton].forEach { addSubview($0) }
        configureLayout()
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Actions

    @objc func deleteButtonDidPress(_ button: UIButton) {
        delegate?.footerView(self, didPressDeleteButton: button)
    }

    @objc func shareButtonDidPress(_ button: UIButton) {
        delegate?.footerView(self, didPressShareButton: button)
    }

    @objc func infoButtonDidPress(_ button: UIButton) {
        delegate?.footerView(self, didPressInfoButton: button)
    }
}

// MARK: - LayoutConfigurable

extension FooterView: LayoutConfigurable {

    @objc public func configureLayout() {
        NSLayoutConstraint.activate([
            // Delete Button Constraints (use safe area for vertical centering)
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            deleteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            deleteButton.widthAnchor.constraint(equalToConstant: 50),
            deleteButton.heightAnchor.constraint(equalToConstant: 50),

            // Share Button Constraints (use safe area for vertical centering)
            shareButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            shareButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            shareButton.widthAnchor.constraint(equalToConstant: 50),
            shareButton.heightAnchor.constraint(equalToConstant: 50),

            // Info Button Constraints (use center X anchor)
            infoButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            infoButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            infoButton.widthAnchor.constraint(equalToConstant: 50),
            infoButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
}
