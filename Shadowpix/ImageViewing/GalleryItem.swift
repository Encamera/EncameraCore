//
//  GalleryItem.swift
//  Shadowpix
//
//  Created by Alexander Freas on 20.06.22.
//

import Foundation
import SwiftUI
import Combine

struct GalleryItem: View {
    
    var fileAccess: FileAccess
    var keyManager: KeyManager
    var media: EncryptedMedia
    @State private var isActive: Bool = false
    
    var body: some View {
        NavigationLink(isActive: $isActive, destination: {
            switch media.mediaType {
            case .photo:
                ImageViewing(viewModel: ImageViewingViewModel<EncryptedMedia, DiskFileAccess<iCloudFilesDirectoryModel>> .init(media: media, keyManager: keyManager))
            case .video:
                MovieViewing<EncryptedMedia, DiskFileAccess<iCloudFilesDirectoryModel>>(viewModel: .init(media: media, keyManager: keyManager))
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
        GalleryView(viewModel: GalleryViewModel(fileAccess: DemoFileEnumerator(), keyManager: KeychainKeyManager(isAuthorized: Just(true).eraseToAnyPublisher()), mediaType: .constant(.photo)))
    }
}
