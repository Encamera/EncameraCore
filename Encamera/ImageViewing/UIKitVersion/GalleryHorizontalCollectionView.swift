//
//  GalleryHorizontalCollectionView.swift
//  Encamera
//
//  Created by Alexander Freas on 08.11.24.
//

import Foundation
import UIKit
import EncameraCore

class GalleryViewController: UIViewController {

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, InteractableMedia<EncryptedMedia>>!
    private let viewModel: GalleryHorizontalCollectionViewModel

    required init(viewModel: GalleryHorizontalCollectionViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        configureDataSource()
        loadImages()
    }

    private func setupCollectionView() {
        let layout = UICollectionViewCompositionalLayout { section, environment in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .fractionalWidth(0.5))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)

            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .fractionalWidth(0.5))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

            let section = NSCollectionLayoutSection(group: group)
            return section
        }

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        view.addSubview(collectionView)

        collectionView.register(MediaCell.self, forCellWithReuseIdentifier: MediaCell.reuseIdentifier)
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, InteractableMedia<EncryptedMedia>>(collectionView: collectionView) { (collectionView, indexPath, mediaItem) -> UICollectionViewCell? in
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MediaCell.reuseIdentifier, for: indexPath) as? MediaCell else {
                fatalError("Unable to dequeue MediaCell")
            }

            cell.configure(with: mediaItem)

            // Load image asynchronously
            self.viewModel.fileAccess.loadImage(for: mediaItem.url) { result in
                DispatchQueue.main.async {
                    guard cell.mediaItem == mediaItem else { return }
                    switch result {
                    case .success(let image):
                        cell.setImage(image)
                    case .failure(let error):
                        print("Failed to load image: \(error)")
                        cell.setPlaceholderImage()
                    }
                }
            }

            return cell
        }
    }

    private func loadImages() {
        // Simulate loading media items
        let mediaItems = (0..<50).map { InteractableMedia<EncryptedMedia>(id: UUID(), url: URL(string: "https://example.com/image\($0).jpg")!) }

        var snapshot = NSDiffableDataSourceSnapshot<Section, InteractableMedia<EncryptedMedia>>()
        snapshot.appendSections([.main])
        snapshot.appendItems(mediaItems, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

private enum Section {
    case main
}

class MediaCell: UICollectionViewCell {
    static let reuseIdentifier = "MediaCell"

    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    var mediaItem: InteractableMedia<EncryptedMedia>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        contentView.addSubview(imageView)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        contentView.addSubview(activityIndicator)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    func configure(with item: InteractableMedia<EncryptedMedia>) {
        mediaItem = item
        imageView.image = nil
        activityIndicator.startAnimating()
    }

    func setImage(_ image: UIImage) {
        imageView.image = image
        activityIndicator.stopAnimating()
    }

    func setPlaceholderImage() {
        imageView.image = UIImage(systemName: "photo")
        activityIndicator.stopAnimating()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        mediaItem = nil
    }
}
