//
//  GalleryItem.swift
//  Encamera
//
//  Created by Alexander Freas on 20.06.22.
//

import Foundation
import SwiftUI
import Combine
import CoreMedia



struct GalleryItem: View {
    
    var fileAccess: FileAccess
    var media: EncryptedMedia
    var galleryViewModel: GalleryViewModel
    @State private var isActive: Bool = false
    
    var body: some View {
            AsyncImage(viewModel: .init(targetMedia: media, loader: fileAccess), placeholder: ProgressView())
            .clipped()
            .aspectRatio(1, contentMode: .fill)
    }
}
struct GalleryItem_Previews: PreviewProvider {
    
    static let fileAccess = DemoFileEnumerator()

    static var previews: some View {
//        GalleryItem(fileAccess: fileAccess, keyManager: KeychainKeyManager(isAuthenticated: Just(true).eraseToAnyPublisher()), media: fileAccess.media.randomElement()!)
        GalleryView(viewModel: GalleryViewModel(fileAccess: DemoFileEnumerator(), keyManager: MultipleKeyKeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(), keyDirectoryStorage: DemoStorageSettingsManager())))
    }
}
