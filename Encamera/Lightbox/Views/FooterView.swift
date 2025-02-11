import UIKit
import EncameraCore

protocol FooterViewDelegate: AnyObject {
    @MainActor
    func footerView(_ footerView: FooterView, didPressButton button: UIButton, buttonType: FooterView.ButtonType)
}

open class MediaInfo: UIView {
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.FooterView.mediaDetails
        label.applyFontType(.pt16, on: .darkBackground, weight: .bold)
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let dateLabel: UILabel = {
        let label = UILabel()
        label.applyFontType(.pt16, on: .darkBackground, weight: .regular)
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let stackView: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(dateLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    func configure(with dateText: String) {
        dateLabel.text = dateText
    }
}

open class FooterView: UIView {
    enum ButtonType: Int {
        case delete, share, info, chevronDown
    }

    open fileprivate(set) lazy var deleteButton: UIButton = createButton(
        type: .delete,
        imageName: "trash",
        tintColor: .systemRed,
        action: #selector(buttonDidPress(_:))
    )

    open fileprivate(set) lazy var shareButton: UIButton = {
        let button = createButton(
            type: .share,
            imageName: "square.and.arrow.up",
            tintColor: .systemBlue,
            action: #selector(buttonDidPress(_:))
        )
        button.isEnabled = false
        return button
    }()
    
    open fileprivate(set) lazy var infoButton: UIButton = createButton(
        type: .info,
        imageName: "info.circle",
        tintColor: .systemGray,
        action: #selector(buttonDidPress(_:))
    )

    open fileprivate(set) lazy var chevronDownButton: UIButton = createButton(
        type: .chevronDown,
        imageName: "chevron.down",
        tintColor: .systemGray,
        action: #selector(buttonDidPress(_:))
    )

    open fileprivate(set) lazy var mediaInfoView: MediaInfo = {
        let view = MediaInfo()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        let gesture = UISwipeGestureRecognizer(target: self, action: #selector(collapseViewFromSwipe))
        gesture.direction = .down
        view.addGestureRecognizer(gesture)
        return view
    }()

    private var purchaseManager: PurchasedPermissionManaging?

    var media: InteractableMedia<EncryptedMedia>! {
        didSet {
            if let timestamp = media.timestamp {
                mediaInfoView.configure(with: DateUtils.dateTimeString(from: timestamp))
            } else {
                mediaInfoView.configure(with: L10n.noInfoAvailable)
            }
            configureShareButton()
        }
    }

    weak var delegate: (any FooterViewDelegate)?

    // MARK: - Initializers

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    convenience init(purchaseManager: PurchasedPermissionManaging) {
        self.init(frame: .zero)
        self.media = media
        self.purchaseManager = purchaseManager
        backgroundColor = UIColor.clear
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)
        blurEffectView.frame = bounds
        blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(blurEffectView, at: 0)

        [deleteButton, shareButton, infoButton, mediaInfoView].forEach { addSubview($0) }
        configureLayout()
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Button Factory Method

    private func createButton(type: ButtonType, imageName: String, tintColor: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.tintColor = tintColor
        button.backgroundColor = UIColor(white: 0.0, alpha: 0.1)
        button.layer.cornerRadius = 25  // Make it round assuming width and height are equal
        button.clipsToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tag = type.rawValue
        return button
    }

    // MARK: - Actions

    @objc func buttonDidPress(_ button: UIButton) {
        guard let buttonType = ButtonType(rawValue: button.tag) else { return }

        switch buttonType {
        case .info:
            expandView()
        case .chevronDown:
            collapseView()
        default:
            break
        }
        delegate?.footerView(self, didPressButton: button, buttonType: buttonType)
    }

    private func expandView() {
        let chevronButtonSize: CGFloat = 50
        let chevronButtonBottomOffset: CGFloat = 0
        let mediaInfoViewSidePadding: CGFloat = 16
        let mediaInfoViewHeight: CGFloat = 80
        let animationDuration: TimeInterval = 0.2

        self.infoButton.isHidden = true
        self.addSubview(self.chevronDownButton)
        self.mediaInfoView.isHidden = false
        self.mediaInfoView.alpha = 0

        NSLayoutConstraint.activate([
            chevronDownButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            chevronDownButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: chevronButtonBottomOffset),
            chevronDownButton.widthAnchor.constraint(equalToConstant: chevronButtonSize),
            chevronDownButton.heightAnchor.constraint(equalToConstant: chevronButtonSize),
            mediaInfoView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: mediaInfoViewSidePadding),
            mediaInfoView.topAnchor.constraint(equalTo: topAnchor, constant: mediaInfoViewSidePadding),
            mediaInfoView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -mediaInfoViewSidePadding),
            mediaInfoView.heightAnchor.constraint(equalToConstant: mediaInfoViewHeight) // Added height constraint
        ])

        layoutIfNeeded()

        UIView.animate(withDuration: animationDuration) {
            self.mediaInfoView.alpha = 1
        }
    }


    @objc private func collapseViewFromSwipe() {
        collapseView()
        delegate?.footerView(self, didPressButton: chevronDownButton, buttonType: .chevronDown)

    }

    private func collapseView() {
        self.chevronDownButton.removeFromSuperview()
        self.infoButton.isHidden = false

        UIView.animate(withDuration: 0.2, animations: {
            self.mediaInfoView.alpha = 0
        }) { _ in
            self.mediaInfoView.isHidden = true
        }
    }

    private func configureShareButton() {
        shareButton.isEnabled = purchaseManager?.hasEntitlement ?? false
    }
}

// MARK: - LayoutConfigurable

extension FooterView: LayoutConfigurable {

    @objc public func configureLayout() {
        let buttonSize: CGFloat = 50
        let buttonBottomOffset: CGFloat = 0
        let deleteButtonTrailingOffset: CGFloat = -26
        let shareButtonLeadingOffset: CGFloat = 26

        NSLayoutConstraint.activate([
            // Delete Button Constraints
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: deleteButtonTrailingOffset),
            deleteButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: buttonBottomOffset),
            deleteButton.widthAnchor.constraint(equalToConstant: buttonSize),
            deleteButton.heightAnchor.constraint(equalToConstant: buttonSize),

            // Share Button Constraints
            shareButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: shareButtonLeadingOffset),
            shareButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: buttonBottomOffset),
            shareButton.widthAnchor.constraint(equalToConstant: buttonSize),
            shareButton.heightAnchor.constraint(equalToConstant: buttonSize),

            // Info Button Constraints
            infoButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            infoButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: buttonBottomOffset),
            infoButton.widthAnchor.constraint(equalToConstant: buttonSize),
            infoButton.heightAnchor.constraint(equalToConstant: buttonSize)
        ])

    }

}
