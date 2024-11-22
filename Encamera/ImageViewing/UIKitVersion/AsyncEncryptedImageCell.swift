//
//  AsyncEncryptedImageCell.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//

import Foundation
import UIKit
import EncameraCore

class AsyncEncryptedImageCell: UICollectionViewCell {
    static let reuseIdentifier = "AsyncEncryptedImageCell"

    // MARK: - UI Components
    private let imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        return imageView
    }()

    private let placeholderView: UIView = {
        let placeholderView = UIView()
        placeholderView.backgroundColor = .systemGray5
        return placeholderView
    }()

    private let downloadIconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "icloud.and.arrow.down"))
        imageView.tintColor = .white
        imageView.isHidden = true
        return imageView
    }()

    private let videoDurationLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.isHidden = true
        return label
    }()

    private let livePhotoIconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "livephoto"))
        imageView.tintColor = .white
        imageView.isHidden = true
        return imageView
    }()

    private let selectionOverlay: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        imageView.tintColor = .blue
        imageView.backgroundColor = .white
        imageView.layer.cornerRadius = imageView.frame.size.width / 2
        imageView.clipsToBounds = true
        imageView.isHidden = true
        return imageView
    }()

    // MARK: - Properties
    private var viewModel: ViewModel?
    var isInSelectionMode = false {
        didSet {
            updateSelectionMode() // Update when the selection mode changes
        }
    }

    var isSelectedCell = false {
        didSet {
            selectionOverlay.isHidden = !isSelectedCell
        }
    }

    // MARK: - ViewModel
    class ViewModel {
        private var loader: FileReader
        private var targetMedia: InteractableMedia<EncryptedMedia>
        var cleartextMedia: PreviewModel?
        var error: Error?

        var needsDownload: Bool {
            return targetMedia.needsDownload
        }

        init(targetMedia: InteractableMedia<EncryptedMedia>, loader: FileReader) {
            self.targetMedia = targetMedia
            self.loader = loader
        }

        func loadPreview(completion: @escaping (Result<PreviewModel, Error>) -> Void) {
            Task {
                do {
                    let preview = try await loader.loadMediaPreview(for: targetMedia)
                    completion(.success(preview))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup
    private func setupViews() {
        contentView.addSubview(placeholderView)
        contentView.addSubview(imageView)
        contentView.addSubview(downloadIconView)
        contentView.addSubview(videoDurationLabel)
        contentView.addSubview(livePhotoIconView)
        contentView.addSubview(selectionOverlay)

        placeholderView.frame = contentView.bounds
        imageView.frame = contentView.bounds
        downloadIconView.frame = CGRect(x: contentView.bounds.maxX - 24, y: contentView.bounds.maxY - 24, width: 20, height: 20)
        videoDurationLabel.frame = CGRect(x: contentView.bounds.maxX - 50, y: contentView.bounds.maxY - 24, width: 50, height: 20)
        livePhotoIconView.frame = CGRect(x: contentView.bounds.maxX - 24, y: contentView.bounds.maxY - 24, width: 20, height: 20)
        selectionOverlay.frame = CGRect(x: contentView.bounds.maxX - 30, y: contentView.bounds.maxY - 30, width: 25, height: 25)
    }

    // MARK: - Configuration
    func configure(with viewModel: ViewModel) {
        self.viewModel = viewModel
        loadPreview()
    }

    private func loadPreview() {
        viewModel?.loadPreview { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let previewModel):
                    self?.handlePreviewSuccess(previewModel)
                case .failure(let error):
                    self?.handlePreviewFailure(error)
                }
            }
        }
    }

    private func handlePreviewSuccess(_ previewModel: PreviewModel) {
        self.placeholderView.isHidden = true
        if let data = previewModel.thumbnailMedia.data, let image = UIImage(data: data) {
            self.imageView.image = image
        }
        if viewModel?.needsDownload == true {
            downloadIconView.isHidden = false
        }
        if let duration = previewModel.videoDuration {
            videoDurationLabel.text = duration
            videoDurationLabel.isHidden = false
        } else if previewModel.isLivePhoto == true {
            livePhotoIconView.isHidden = false
        }
    }

    private func handlePreviewFailure(_ error: Error) {
        placeholderView.isHidden = false
        imageView.image = nil
        // Handle different error cases
        if let secretError = error as? SecretFilesError {
            switch secretError {
            case .createVideoThumbnailError:
                imageView.image = UIImage(systemName: "play.rectangle.fill")
            default:
                imageView.image = UIImage(systemName: "x.square")
            }
        }
    }

    private func updateSelectionMode() {
        if isInSelectionMode {
            let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(didTapCell))
            contentView.addGestureRecognizer(tapGestureRecognizer)
        } else {
            contentView.gestureRecognizers?.forEach(contentView.removeGestureRecognizer)
        }
    }

    @objc private func didTapCell() {
        isSelectedCell.toggle()
    }
}
