//
//  KeyExchange.swift
//  Encamera
//
//  Created by Alexander Freas on 07.09.22.
//

import SwiftUI
import EncameraCore


class KeyExchangeViewModel: ObservableObject {
    
    var key: PrivateKey
    @Published var blurView = true
    
    init(key: PrivateKey) {
        self.key = key
    }
    
}

struct KeyExchange: View {
    
    @StateObject var viewModel: KeyExchangeViewModel
    
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            
            VStack(alignment: .center) {
                Text(L10n.ShareYourEncryptionKeyWithSomeoneYouTrust.sharingItWithThemMeansTheyCanDecryptAnyMediaYouShareWithThemThatIsEncryptedWithThisKey)
                    .fontType(.small)
                
                Spacer()
                    .frame(height: 30)
                ZStack {
                    createQrImage(geo: geo)
                        .frame(width: frame.width, height: frame.width)
                        .blur(radius: viewModel.blurView ? 10 : 0)
                    Text("\(viewModel.key.name)")
                        .fontType(.medium)
                        .frame(maxWidth: .infinity)
                        .background(Color.foregroundSecondary)
                        .opacity(viewModel.blurView ? 1.0 : 0.0)
                }
                
                .background(Color.foregroundSecondary)
                .cornerRadius(20)
                
                Button(L10n.holdToReveal) {
                    
                }.onLongPressGesture(perform: {
                    
                }, onPressingChanged: { pressed in
                    setBlur(to: !pressed)
                })
                    .primaryButton()
                    
                    

            }
        }
        .padding(30)
        .navigationTitle(L10n.shareKey)
        .background(Color.background)
        .screenBlocked()
    }
    
    private func setBlur(to target: Bool) {
        guard viewModel.blurView != target else { return }
        withAnimation {
            viewModel.blurView = target
        }
        
    }
    
    func createQrImage(geo: GeometryProxy) -> some View {
        var imageView: Image
        
        if let keyString = LocalDeeplinkingUtils.deeplinkFor(key: viewModel.key) {
            let image = QRCodeGenerator.generateQRCode(from: keyString.absoluteString, size: geo.size)
            imageView = Image(uiImage: image)
        } else {
            imageView = Image(systemName: "lock.slash")
        }
        
        return imageView
            .resizable()
            .aspectRatio(1.0, contentMode: .fit)
            .frame(width: geo.size.width*0.75)
    }

}

struct KeyExchange_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            KeyExchange(viewModel: .init(key: DemoPrivateKey.dummyKey()))
        }
        
    }
}
