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

        collectionView.register(AsyncEncryptedImageCell.self, forCellWithReuseIdentifier: AsyncEncryptedImageCell.reuseIdentifier)
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, InteractableMedia<EncryptedMedia>>(collectionView: collectionView) { (collectionView, indexPath, mediaItem) -> UICollectionViewCell? in
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AsyncEncryptedImageCell.reuseIdentifier, for: indexPath) as? AsyncEncryptedImageCell else {
                fatalError("Unable to dequeue AsyncEncryptedImageCell")
            }

            let cellViewModel = AsyncEncryptedImageCell.ViewModel(targetMedia: mediaItem, loader: self.viewModel.fileAccess)
            cell.configure(with: cellViewModel)

            return cell
        }
    }

    private func loadImages() {
        // Simulate loading media items

        var snapshot = NSDiffableDataSourceSnapshot<Section, InteractableMedia<EncryptedMedia>>()
        snapshot.appendSections([.main])
        snapshot.appendItems(viewModel.media, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

private enum Section {
    case main
}
