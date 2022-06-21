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

struct KeyPickerView: View {
    
    @State var isShowingSheetForKeyEntry: Bool = false
    @State var isShowingSheetForNewKey: Bool = false
    @State var isShowingAlertForClearKey: Bool = false
    @Binding var isShown: Bool
    @EnvironmentObject var appState: ShadowPixState
    
    
    
    private struct Constants {
        static var outerPadding = 20.0
    }
    func createQrImage(geo: GeometryProxy) -> some View {
        var imageView: Image
        
        if let keyString = appState.keyManager.currentKey?.base64String {
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
        NavigationView {
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
                    Text(appState.keyManager.currentKey?.name ?? "no key")
                        .padding()
                        .font(Font.largeTitle)
                }
                List {
                    if appState.keyManager.currentKey != nil {
                        Button("Copy Key to Clipboard") {
                            UIPasteboard.general.string = appState.keyManager.currentKey?.base64String
                        }
                    }
                    Button("Set key") {
                        isShowingSheetForKeyEntry = true
                    }
                    NavigationLink {
                        KeyGeneration(isShown: $isShowingSheetForNewKey)
                            .environmentObject(appState)
                    } label: {
                        Text("Generate new key")
                    }

                    
                    Button {
                        isShowingAlertForClearKey = true
                    } label: {
                        Text("Clear key")
                            .foregroundColor(.red)
                    }
                }.alert(isPresented: $isShowingAlertForClearKey) {
                    Alert(title: Text("Clear key"), message: Text("Do you really want to clear the current key in the keychain?"), primaryButton:
                                .cancel(Text("Cancel")) {
                        isShowingAlertForClearKey = false
                    }, secondaryButton: .destructive(Text("Clear")) {
                        do {
                            try appState.keyManager.clearStoredKeys()
                            isShowingAlertForClearKey = false
                        } catch {
                            print("Error clearing keychain", error)
                        }
                    })}
            }
            
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("Close") {
                        isShown = false
                    }
                }

            }
            
        }.sheet(isPresented: $isShowingSheetForNewKey) {
            
        }.sheet(isPresented: $isShowingSheetForKeyEntry) {
            isShown = false
        } content: {
            KeyEntry(viewModel: KeyEntry.ViewModel(keyManager: appState.keyManager, isShowing: $isShowingSheetForNewKey))
                .environmentObject(appState)
        }
        .foregroundColor(.blue)
        
    }
}

struct KeyPickerView_Previews: PreviewProvider {
    static var previews: some View {
            KeyPickerView(isShowingSheetForNewKey: false, isShown: .constant(true))
                .environmentObject(ShadowPixState())
.preferredColorScheme(.dark)
            KeyPickerView(isShowingSheetForNewKey: false, isShown: .constant(true))
                .environmentObject(ShadowPixState())
            .preferredColorScheme(.light)

    }
}
