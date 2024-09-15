//
//  MediaSelectionTray.swift
//  Encamera
//
//  Created by Alexander Freas on 15.09.24.
//

import SwiftUI
import EncameraCore

struct MediaSelectionTray: View {

    var shareAction: () -> Void
    var deleteAction: () -> Void
    @Binding var selectedMedia: Set<InteractableMedia<EncryptedMedia>>
    @State private var selectedMediaCount: Int = 0
    var body: some View {
        HStack {

            Button {
                shareAction()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .opacity(selectedMediaCount > 0 ? 1.0 : 0.0)
            Spacer()
            Text(selectedMediaCount == 0 ? L10n.MediaSelectionTray.selectMedia : "\(selectedMediaCount) \(L10n.MediaSelectionTray.itemSelected)")
            Spacer()
            Button {
                deleteAction()
            } label: {
                Image(systemName: "trash")
            }
            .opacity(selectedMediaCount > 0 ? 1.0 : 0.0)
        }
        .onAppear {
            selectedMediaCount = selectedMedia.count
        }
        .onChange(of: selectedMedia, { oldValue, newValue in
            selectedMediaCount = newValue.count
        })
        .padding()
        .frame(height: 75)
        .background(Color.black)

    }
}

#Preview {
    VStack {
        MediaSelectionTray(shareAction: {

        }, deleteAction: {

        }, selectedMedia: .constant(Set<InteractableMedia<EncryptedMedia>>()))
        MediaSelectionTray(shareAction: {

        }, deleteAction: {

        }, selectedMedia: .constant(Set<InteractableMedia<EncryptedMedia>>([
            InteractableMedia(emptyWithType: .livePhoto, id: "234")
        ])))

    }.background(Color.white)
}
