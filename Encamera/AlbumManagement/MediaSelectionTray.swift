import SwiftUI
import EncameraCore

struct MediaSelectionTray: View {

    var shareAction: () -> Void
    var deleteAction: () -> Void

    @Binding var selectedMedia: Set<InteractableMedia<EncryptedMedia>>
    @Binding var showShareOption: Bool
    @State private var selectedMediaCount: Int = 0

    var body: some View {
        ZStack {
            HStack {
                Spacer()
                Menu {
//                    Button(action: {
//
//                    }) {
//                        Label(L10n.MediaSelectionTray.moveMedia, systemImage: "folder")
//                    }
                    if showShareOption {
                        Button(action: {
                            shareAction()
                        }) {
                            Label(L10n.share, systemImage: "square.and.arrow.up")
                        }
                    }

                    Button(role: .destructive, action: {
                        deleteAction()
                    }) {
                        Label(L10n.delete, systemImage: "trash")
                    }

                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.white)
                        .opacity(selectedMediaCount > 0 ? 1.0 : 0.0)
                        .frame(maxWidth: 75, maxHeight: .infinity)
                        .padding(0)
                }

            }
            Text(selectedMediaCount == 0 ? L10n.MediaSelectionTray.selectMedia : "\(L10n.imageS(selectedMedia.count)) \(L10n.MediaSelectionTray.itemSelected)")
                .foregroundColor(.white)
        }
        .onAppear {
            selectedMediaCount = selectedMedia.count
        }
        .onChange(of: selectedMedia) { _, newValue in
            selectedMediaCount = newValue.count
        }
        .background(Color.black)
        .frame(height: 75)
    }
}

#Preview {
    VStack {
        MediaSelectionTray(shareAction: {

        }, deleteAction: {

        }, selectedMedia: .constant(Set<InteractableMedia<EncryptedMedia>>()), showShareOption: .constant(false))
        MediaSelectionTray(shareAction: {

        }, deleteAction: {

        }, selectedMedia: .constant(Set<InteractableMedia<EncryptedMedia>>([
            InteractableMedia(emptyWithType: .livePhoto, id: "234")
        ])), showShareOption: .constant(true))

    }.background(Color.white)
}
