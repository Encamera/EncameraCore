//
//  AddAlbumModal.swift
//  Encamera
//
//  Created by Alexander Freas on 22.01.24.
//

import SwiftUI
import EncameraCore
import SwiftUIIntrospect

struct AddAlbumModal: View {
    var saveAction: ((String) -> Void)?
    @State var albumName: String = ""

    @Environment(\.presentationMode) private var presentationMode


    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Image("Down-Chevron")
                }

                Spacer()
                Button {
                    guard albumName.count > 1 else {
                        return
                    }
                    saveAction?(albumName)
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text(L10n.save)
                }.textButton()
            }
            .pad(.pt24)
            Spacer().frame(height: 40)
            VStack(alignment: .leading) {
                Text(L10n.letsGiveYourAlbumAName)
                    .fontType(.pt32, weight: .bold)
                    .multilineTextAlignment(.leading)
                    .pad(.pt64, edge: .bottom)
                Text(L10n.albumName.uppercased())
                    .fontType(.pt14, weight: .bold)
                    .opacity(AppConstants.lowOpacity)
                UnderlineTextField(text: $albumName)
                    .noAutoModification()
                    .pad(.pt8, edge: .bottom)
                    .offset(.init(width: -Spacing.pt16.value, height: 0))
                    .introspect(.textField, on: .iOS(.v13, .v14, .v15, .v16, .v17)) { (textField: UITextField) in
                        textField.becomeFirstResponder()
                    }

            }
            .pad(.pt24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.modalBackgroundColor)
    }
}

#Preview {

    Color.orange.sheet(isPresented: .constant(true), content: {
        AddAlbumModal()
    })

}
