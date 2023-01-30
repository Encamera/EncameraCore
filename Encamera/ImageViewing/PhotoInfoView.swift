//
//  PhotoInfoView.swift
//  Encamera
//
//  Created by Alexander Freas on 11.10.22.
//

import SwiftUI
import EncameraCore

struct PhotoInfoView: View {
    
    var media: EncryptedMedia
    
    
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
        let dateComponents = DateComponents(timeZone: TimeZone(identifier: "gmt"), year: 2022, month: 2, day: 9, hour: 5, minute: 0, second: 0)
        let date = Calendar(identifier: .gregorian).date(from: dateComponents)
        media.timestamp = date
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
            PhotoInfoView(media: media, isPresented: binding)
                .presentationDetents([.fraction(0.1)])
        }.previewDevice("iPhone 7")
        
    }
}
