//
//  ShareHandling.swift
//  Encamera
//
//  Created by Alexander Freas on 23.01.23.
//

import SwiftUI
import EncameraCore

struct ShareHandling: View {
    
    var cleartextData: Data
    var fileAccess: FileAccess
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            
            if  let image = UIImage(data: cleartextData) {
                VStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                .navigationTitle(L10n.sharedMedia)
                .navigationBarItems(trailing: Button(L10n.save) {
                    Task {
                        try await fileAccess.save(media: CleartextMedia(source: cleartextData))
                        SharedFileAccess.deleteSharedData()
                        dismiss()
                    }
                })
            } else {
                EmptyView()
            }
            
        }
    }
}

struct ShareHandling_Previews: PreviewProvider {
    static var previews: some View {
        ShareHandling(cleartextData: UIImage(named: "2.JPG")!.pngData()!, fileAccess: DemoFileEnumerator())
    }
}
