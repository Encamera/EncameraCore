//
//  ImageViewing.swift
//  shadowpix
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Photos

struct ImageViewing: View {
    
    class ViewModel: ObservableObject {
        @Published var image: ShadowPixMedia
        
        init(image: ShadowPixMedia) {
            self.image = image
        }
        
        func decryptImage() {
            image.loadImage()
        }
    }
    @EnvironmentObject var state: ShadowPixState
    @ObservedObject var viewModel: ViewModel
    var body: some View {
        VStack {
            if let imageData = viewModel.image.decryptedImage,  state.isAuthorized {
                Image(uiImage: imageData.image).resizable().scaledToFit()
            } else {
                Text("Could not decrypt image")
                    .foregroundColor(.red)
            }
        }.onAppear {
            self.viewModel.decryptImage()
        }
    }
}

struct ImageViewing_Previews: PreviewProvider {
    static var previews: some View {
        ImageViewing(viewModel: ImageViewing.ViewModel(image: ShadowPixMedia(url: Bundle.main.url(forResource: "shadowimage.shdwpic", withExtension: nil)!)))
    }
    
}
