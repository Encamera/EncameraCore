//
//  PhotoInfoView.swift
//  Encamera
//
//  Created by Alexander Freas on 11.10.22.
//

import SwiftUI
import EncameraCore

struct PhotoInfoView: View {
    
    var media: InteractableMedia<EncryptedMedia>
    
    
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if let timestamp = media.timestamp {
                    Text(verbatim: DateUtils.dateTimeString(from: timestamp))
                } else {
                    Text(L10n.noInfoAvailable)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.down")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                .padding()
                .frame(width: 50, height: 50)
            }
            .padding()
            Spacer()
        }
        .background(Color.background)
        
    }
}

@available(iOS 16.0, *)
struct PhotoInfoView_Previews: PreviewProvider {
    
    static var media: EncryptedMedia {
        let media = EncryptedMedia(source: URL(string: "file://")!, mediaType: .photo, id: NSUUID().uuidString)
        return media
    }
    
    static var shouldDisplay = true
    
    static var previews: some View {
        let binding = Binding<Bool> {
            return shouldDisplay
        } set: { value in
            shouldDisplay = value
        }
        Color.black.sheet(isPresented: binding) {
            PhotoInfoView(media: try! InteractableMedia(underlyingMedia: [media]), isPresented: binding)
                .presentationDetents([.fraction(0.1)])
        }.previewDevice("iPhone 7")
        
    }
}
