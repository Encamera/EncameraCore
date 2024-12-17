import SwiftUI
import EncameraCore

struct MediaSelectionTray: View {

    var shareAction: () -> Void
    var deleteAction: () -> Void

    @Binding var selectedMedia: Set<InteractableMedia<EncryptedMedia>>
    @Binding var showShareOption: Bool
    @State private var selectedMediaCount: Int = 0

    var body: some View {
        VStack {
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
                        ZStack {
                            Circle()
                                .fill(Color.gray.opacity(0.4))
                                .frame(width: 50, height: 50)
                            Image(systemName: "ellipsis.circle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20) // Adjust icon size
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: 50, maxHeight: .infinity)
                        .padding(0)
                        .opacity(selectedMediaCount > 0 ? 1.0 : 0.0)
                    }
                    Spacer().frame(width: 26)
                }
                Text(selectedMediaCount == 0 ? L10n.MediaSelectionTray.selectMedia : "\(L10n.imageS(selectedMedia.count)) \(L10n.MediaSelectionTray.itemSelected)")
                    .foregroundColor(.white)
            }
            Spacer().frame(height: 18)
        }
        .onAppear {
            selectedMediaCount = selectedMedia.count
        }
        .onChange(of: selectedMedia) { _, newValue in
            selectedMediaCount = newValue.count
        }
        .background(Color.black)
        .frame(height: 98)
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
