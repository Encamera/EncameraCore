//
//  ImageViewing.swift
//  shadowpix
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI

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
            guard let data = try? Data(contentsOf: imageUrl), let decrypted: UIImage = ChaChaPolyHelpers.decrypt(encryptedContent: data) else {
                print("Could not open image")
                return nil
            }
            
            return decrypted
        }
    }
    @ObservedObject var viewModel: ViewModel
    var body: some View {
        VStack {
            if let imageData = viewModel.decryptImage() {
                Image(uiImage: imageData).resizable().scaledToFit()
            }
        }
    }
}

struct ImageViewing_Previews: PreviewProvider {
    static var previews: some View {
        ImageViewing(viewModel: ImageViewing.ViewModel(imageUrl: Bundle.main.url(forResource: "shadowimage.shdwpic", withExtension: nil)!))
    }
    
}
