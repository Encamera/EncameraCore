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
        GalleryGridView(viewModel: GalleryGridViewModel(privateKey: DemoPrivateKey.dummyKey()))
    }
}
