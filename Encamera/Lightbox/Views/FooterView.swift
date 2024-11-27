import UIKit

protocol FooterViewDelegate: AnyObject {
    @MainActor
    func footerView(_ footerView: FooterView, didPressButton button: UIButton, buttonType: FooterView.ButtonType)
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

    open fileprivate(set) lazy var shareButton: UIButton = createButton(
        type: .share,
        imageName: "square.and.arrow.up",
        tintColor: .systemBlue,
        action: #selector(buttonDidPress(_:))
    )

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

    open fileprivate(set) lazy var helloWorldLabel: UILabel = {
        let label = UILabel()
        label.text = "Hello World"
        label.textColor = .black
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    weak var delegate: (any FooterViewDelegate)?

    // MARK: - Instance Variables

    private var originalHeight: CGFloat = 0

    // MARK: - Initializers

    public override init(frame: CGRect) {
        super.init(frame: frame)
        originalHeight = frame.height
        backgroundColor = UIColor.clear
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        let blurEffectView = UIVisualEffectView(effect: blurEffect)
        blurEffectView.frame = bounds
        blurEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(blurEffectView, at: 0)  // Ultra-thin frosted background

        [deleteButton, shareButton, infoButton, helloWorldLabel].forEach { addSubview($0) }
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
        self.infoButton.isHidden = true
        self.addSubview(self.chevronDownButton)
        self.helloWorldLabel.isHidden = false

        NSLayoutConstraint.activate([
            chevronDownButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            chevronDownButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            chevronDownButton.widthAnchor.constraint(equalToConstant: 50),
            chevronDownButton.heightAnchor.constraint(equalToConstant: 50),
            helloWorldLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            helloWorldLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        layoutIfNeeded()
    }

    private func collapseView() {
            self.chevronDownButton.removeFromSuperview()
            self.infoButton.isHidden = false
            self.helloWorldLabel.isHidden = true
            }
}

// MARK: - LayoutConfigurable

extension FooterView: LayoutConfigurable {

    @objc public func configureLayout() {
        NSLayoutConstraint.activate([
            // Delete Button Constraints
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            deleteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            deleteButton.widthAnchor.constraint(equalToConstant: 50),
            deleteButton.heightAnchor.constraint(equalToConstant: 50),

            // Share Button Constraints
            shareButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            shareButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            shareButton.widthAnchor.constraint(equalToConstant: 50),
            shareButton.heightAnchor.constraint(equalToConstant: 50),

            // Info Button Constraints
            infoButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            infoButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            infoButton.widthAnchor.constraint(equalToConstant: 50),
            infoButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
}
