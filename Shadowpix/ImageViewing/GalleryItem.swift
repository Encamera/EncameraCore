//
//  GalleryItem.swift
//  Shadowpix
//
//  Created by Alexander Freas on 20.06.22.
//

import Foundation
import SwiftUI
import Combine
import CoreMedia


class PreviewModel: Codable {
    
    var id: String
    
    var thumbnailMedia: CleartextMedia<Data>
    var gridID: String {
        "\(thumbnailMedia.mediaType.fileExtension)_\(thumbnailMedia.id)"
    }
    var videoDuration: String?
    
    init(source: CleartextMedia<Data>) {
        let decoded = try! JSONDecoder().decode(PreviewModel.self, from: source.source)
        self.id = decoded.id
        self.thumbnailMedia = decoded.thumbnailMedia
        self.videoDuration = decoded.videoDuration
    }
    
    init(thumbnailMedia: CleartextMedia<Data>) {
        self.thumbnailMedia = thumbnailMedia
        self.id = thumbnailMedia.id
    }
    
}

struct GalleryItem: View {
    
    var fileAccess: FileAccess
    var media: EncryptedMedia
    @State private var isActive: Bool = false
    
    var body: some View {
        NavigationLink(isActive: $isActive, destination: {
            switch media.mediaType {
            case .photo:
                ImageViewing(viewModel: ImageViewingViewModel<EncryptedMedia>.init(media: media, fileAccess: fileAccess))
            case .video:
                MovieViewing<EncryptedMedia>(viewModel: .init(media: media, fileAccess: fileAccess))
            default:
                EmptyView()
            }
        }, label: {
            AsyncImage(viewModel: .init(targetMedia: media, loader: fileAccess)) {
                ProgressView()
            }
            .clipped()
            .aspectRatio(1, contentMode: .fill)
            
        }).onTapGesture {
            isActive = true
        }
    }
}
struct GalleryItem_Previews: PreviewProvider {
    
    static let fileAccess = DemoFileEnumerator()

    static var previews: some View {
//        GalleryItem(fileAccess: fileAccess, keyManager: KeychainKeyManager(isAuthorized: Just(true).eraseToAnyPublisher()), media: fileAccess.media.randomElement()!)
        GalleryView(viewModel: GalleryViewModel(fileAccess: DemoFileEnumerator(), keyManager: MultipleKeyKeychainManager(isAuthorized: Just(true).eraseToAnyPublisher())))
    }
}
