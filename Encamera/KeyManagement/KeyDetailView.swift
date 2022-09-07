//
//  KeyPickerView.swift
//  encamera
//
//  Created by Alexander Freas on 09.11.21.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

private func generateQRCode(from string: String, size: CGSize) -> UIImage {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    
    let data = Data(string.utf8)
    filter.setValue(data, forKey: "inputMessage")
    guard let output = filter.outputImage else {
        fatalError("no image")
    }
    let x = size.width / output.extent.size.width
    let y = size.height / output.extent.size.height
    
    let qrCodeImage = output.transformed(by: CGAffineTransform(scaleX: x, y: y))
    
    if let qrCodeCGImage = context.createCGImage(qrCodeImage, from: qrCodeImage.extent) {
        return UIImage(cgImage: qrCodeCGImage)
    }
    
    return UIImage(systemName: "xmark") ?? UIImage()
}

class KeyDetailViewModel: ObservableObject {
    
    enum KeyViewerError {
        case couldNotSetKeychain
    }
    
    @Published var keyManager: KeyManager
    @Published var isShowingAlertForClearKey: Bool = false
    @Published var keyViewerError: KeyViewerError?
    @Published var deleteKeyConfirmation: String = ""
    var key: PrivateKey
    
    init(keyManager: KeyManager, key: PrivateKey) {
        self.keyManager = keyManager
        self.key = key
    }
    
    func setActive() {
        do {
            try keyManager.setActiveKey(key.name)
        } catch {
            keyViewerError = .couldNotSetKeychain
        }
    }
    
    func deleteKey() {
        do {
            try keyManager.deleteKey(key)
            isShowingAlertForClearKey = false
        } catch {
            debugPrint("Error clearing keychain", error)
        }
    }
    
    func canDeleteKey() -> Bool {
        deleteKeyConfirmation == key.name
    }
}

struct KeyDetailView: View {
    
    @State var isShowingAlertForClearKey: Bool = false
    @StateObject var viewModel: KeyDetailViewModel
    
    @Environment(\.dismiss) var dismiss
    
    private struct Constants {
        static var outerPadding = 20.0
    }
    func createQrImage(geo: GeometryProxy) -> some View {
        var imageView: Image
        
        if let keyString = viewModel.key.base64String {
            let image = generateQRCode(from: keyString, size: geo.size)
            imageView = Image(uiImage: image)
        } else {
            imageView = Image(systemName: "lock.slash")
        }
        
        return AnyView(imageView
            .resizable()
            .aspectRatio(1.0, contentMode: .fit)
            .frame(width: geo.size.width*0.75))
    }
    var body: some View {
        GalleryGridView(viewModel: .init(privateKey: viewModel.key)) {
            List {
                Button("Set Active") {
                    viewModel.setActive()
                    dismiss()
                }
                NavigationLink {
                    
                } label: {
                    Button("Share Key") {
                        
                    }
                }

                
                Button {
                    isShowingAlertForClearKey = true
                } label: {
                    Text("Delete")
                        .foregroundColor(.red)
                }
            }.frame(height: 200)
        }
        .foregroundColor(.blue)
        .alert("Delete Key?", isPresented: $isShowingAlertForClearKey, actions: {
            TextField("Key name", text: $viewModel.deleteKeyConfirmation)
                .noAutoModification()
            Button("Delete", role: .destructive) {
                if viewModel.canDeleteKey() {
                    viewModel.deleteKey()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {
                isShowingAlertForClearKey = false
            }
        }, message: {
            Text("Enter the name of the key to delete it forever.")
        })
    }
}

struct KeyPickerView_Previews: PreviewProvider {
    static var previews: some View {
        KeyDetailView(viewModel: .init(keyManager: DemoKeyManager(), key: PrivateKey(name: "whoop", keyBytes: [], creationDate: Date())))
            .preferredColorScheme(.dark)
    }
}
