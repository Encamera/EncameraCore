//
//  GalleryView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI

struct GalleryView: View {
    var body: some View {
        VStack {
            Text("images")
        }.onAppear {
            guard let key = ShadowPixState.shared.selectedKey else {
                return
            }
            iCloudFilesManager.enumerateImagesFor(key: key)
        }
    }
}

struct GalleryView_Previews: PreviewProvider {
    static var previews: some View {
        GalleryView()
    }
}
