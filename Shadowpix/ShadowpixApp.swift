//
//  ShadowpixApp.swift
//  Shadowpix
//
//  Created by Rolando Rodriguez on 10/15/20.
//

import SwiftUI

@main
struct ShadowpixApp: App {
    @State var hasOpenedUrl: Bool = false
    class ViewModel: ObservableObject {
        var openedUrl: URL?
    }
    
    
    @StateObject var viewModel: ViewModel = ViewModel()

    var body: some Scene {
        WindowGroup {
            CameraView().sheet(isPresented: $hasOpenedUrl) {
                self.hasOpenedUrl = false
            } content: {
                if let url = viewModel.openedUrl {
                    ImageViewing(viewModel: ImageViewing.ViewModel(imageUrl: url))
                }
            }.onOpenURL { url in
                print(url)
                
                self.viewModel.openedUrl = url
                self.hasOpenedUrl = true
            }
        }
    }
}
