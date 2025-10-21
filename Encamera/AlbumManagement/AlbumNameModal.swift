import SwiftUI
import EncameraCore

struct AlbumNameModal: View {
    var saveAction: ((String) -> Void)?
    @State var albumName: String = ""
    var isEditing: Bool = false
    @FocusState private var isTextFieldFocused: Bool

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
                Text(isEditing ? L10n.AddAlbumModal.renameAlbumTitle : L10n.letsGiveYourAlbumAName)
                    .fontType(.pt32, weight: .bold)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2, reservesSpace: true)
                    .pad(.pt64, edge: .bottom)
                Text(L10n.albumName.uppercased())
                    .fontType(.pt14, weight: .bold)
                    .opacity(AppConstants.lowOpacity)
                UnderlineTextField(text: $albumName)
                    .noAutoModification()
                    .pad(.pt8, edge: .bottom)
                    .offset(.init(width: -Spacing.pt16.value, height: 0))
                    .focused($isTextFieldFocused)
                    .onChange(of: albumName) { oldValue, newValue in
                        if newValue.count > AppConstants.maxCharacterAlbumName {
                            albumName = oldValue
                        }
                    }
            }
            .pad(.pt24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.modalBackgroundColor)
        .onAppear {
            isTextFieldFocused = true
        }
    }

}

#Preview {

        AlbumNameModal()

}
