//
//  KeyPickerView.swift
//  shadowpix
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

class KeyViewerViewModel: ObservableObject {
    
    enum KeyViewerError {
        case couldNotSetKeychain
    }
    
    @Published var keyManager: KeyManager
    @Published var isShowingAlertForClearKey: Bool = false
    @Published var keyViewerError: KeyViewerError?
    var key: ImageKey
    
    init(keyManager: KeyManager, key: ImageKey) {
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
            print("Error clearing keychain", error)
        }
    }
}

struct KeyPickerView: View {
    
    @State var isShowingAlertForClearKey: Bool = false
    @ObservedObject var viewModel: KeyViewerViewModel
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
            VStack {
                GeometryReader { geo in
                    
                    Spacer(minLength: geo.safeAreaInsets.top)
                    HStack {
                        Spacer()
                        createQrImage(geo: geo)
                        Spacer()
                    }
                }
                HStack {
                    Text(viewModel.key.name)
                        .padding()
                        .font(Font.largeTitle)
                }
                List {
                    Button("Set Active") {
                        viewModel.setActive()
                        dismiss()
                    }
                    Button("Copy Key to Clipboard") {
                        UIPasteboard.general.string = viewModel.key.base64String
                    }
                    Button {
                        isShowingAlertForClearKey = true
                    } label: {
                        Text("Delete")
                            .foregroundColor(.red)
                    }
                }
                
            }
            .foregroundColor(.blue)
            .alert(isPresented: $isShowingAlertForClearKey) {
                Alert(title: Text("Clear key"), message: Text("Do you really want to clear the current key in the keychain?"), primaryButton:
                        .cancel(Text("Cancel")) {
                            isShowingAlertForClearKey = false
                        }, secondaryButton: .destructive(Text("Clear")) {
                            viewModel.deleteKey()
                            dismiss()
                        })}
        
    }
}

struct KeyPickerView_Previews: PreviewProvider {
    static var previews: some View {
        KeyPickerView(viewModel: .init(keyManager: DemoKeyManager(), key: ImageKey(name: "whoop", keyBytes: [], creationDate: Date())))
            .preferredColorScheme(.dark)
    }
}
