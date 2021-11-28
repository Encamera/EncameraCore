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
        var imageUrl: URL
        
        init(imageUrl: URL) {
            self.imageUrl = imageUrl
        }
        
        func decryptImage() -> UIImage? {
            #if targetEnvironment(simulator)
            return UIImage(named: "background")
            #endif
            return iCloudFilesManager.getImageAt(url: imageUrl)
        }
    }
    @ObservedObject var viewModel: ViewModel
    var body: some View {
        VStack {
            if let imageData = viewModel.decryptImage() {
                Image(uiImage: imageData).resizable().scaledToFit()
            } else {
                Text("Could not decrypt image")
                    .foregroundColor(.red)
            }
        }
    }
}

struct ImageViewing_Previews: PreviewProvider {
    static var previews: some View {
        ImageViewing(viewModel: ImageViewing.ViewModel(imageUrl: Bundle.main.url(forResource: "shadowimage.shdwpic", withExtension: nil)!))
    }
    
}
