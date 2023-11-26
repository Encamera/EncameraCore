//
//  KeyPickerView.swift
//  encamera
//
//  Created by Alexander Freas on 09.11.21.
//

import SwiftUI
import EncameraCore
import Combine


class AlbumDetailViewModel: ObservableObject {
    
    enum KeyViewerError {
        case couldNotSetKeychain
    }
    var albumManager: AlbumManaging

    @Published var keyViewerError: KeyViewerError?
    @Published var deleteAlbumConfirmation: String = ""
    @Published var deleteActionError: String = ""
    @Published var showDeleteActionError = false

    var fileManager: FileAccess?
    var key: PrivateKey
    var album: Album

    private var cancellables = Set<AnyCancellable>()

    init(albumManager: AlbumManaging, fileManager: FileAccess? = nil, key: PrivateKey, album: Album) {
        self.albumManager = albumManager
        self.fileManager = fileManager
        self.key = key
        self.album = album
        Task {
            self.fileManager = await DiskFileAccess(for: album, with: key, albumManager: albumManager)
        }
    }


    func deleteAlbum() {
        albumManager.delete(album: album)
    }

    func canDeleteKey() -> Bool {
//        if #available(iOS 16.0, *) {
//            return deleteAlbumConfirmation == album.name
//        } else {
            return true
//        }
    }
}

struct AlbumDetailView: View {
    
    @State var isShowingAlertForClearKey: Bool = false
    @State var isShowingAlertForDeleteAllAlbumData: Bool = false
    @State var isShowingAlertForCopyKey: Bool = false
    @StateObject var viewModel: AlbumDetailViewModel
    
    @Environment(\.dismiss) var dismiss
    
    private struct Constants {
        static var outerPadding = 20.0
    }
    
    var body: some View {
        GalleryGridView(viewModel: GalleryGridViewModel<EncryptedMedia>(privateKey: viewModel.key, album: viewModel.album, albumManager: viewModel.albumManager, blurImages: false)) {
            ZStack(alignment: .leading) {

                Color.inputFieldBackgroundColor
                    .frame(height:230)

                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: getSafeAreaTop() / 2)
                    HStack(alignment: .top) {
                        Button {
                            dismiss()
                        } label: {
                            Image("Album-BackButton")
                        }
                        .frame(width: 44, height: 44)
                        Spacer()
                        Menu {
                            Button(L10n.viewInFiles) {
                                LocalDeeplinkingUtils.openAlbumContentsInFiles(album: viewModel.album)
                            }
                            Button(L10n.deleteAlbum, role: .destructive) {
                                isShowingAlertForDeleteAllAlbumData = true
                            }
                        } label: {
                            Image("Album-OptionsDots")
                        }.frame(width: 44, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 24)
                        Text(viewModel.album.name)
                            .fontType(.pt24, weight: .bold)
                        Spacer().frame(height: 8)
                        Text(viewModel.album.creationDate.formatted())
                            .fontType(.pt14)
                        Spacer().frame(height: 24)
                        Button {

                        } label: {
                            Text(L10n.addPhotos)
                                .fontType(.pt14, on: .textButton, weight: .bold)
                        }
                    }.padding(.init(top: .zero, leading: 24, bottom: .zero, trailing: 24))
                }

            }
        }
        .screenBlocked()
        .alert(L10n.copiedToClipboard, isPresented: $isShowingAlertForCopyKey, actions: {
            Button(L10n.ok) {
                isShowingAlertForCopyKey = false
            }
        }, message: {
            Text(L10n.KeyCopiedToClipboard.storeThisInAPasswordManagerOrOtherSecurePlace)
        })
        .alert(L10n.deleteAllAssociatedData, isPresented: $isShowingAlertForDeleteAllAlbumData, actions: {
//            if #available(iOS 16.0, *) {
//
//                TextField(L10n.keyName, text: $viewModel.deleteAlbumConfirmation)
//                    .noAutoModification()
//            }
            Button(L10n.deleteEverything, role: .destructive) {

                    viewModel.deleteAlbum()
                    dismiss()

            }
            Button(L10n.cancel, role: .cancel) {
                isShowingAlertForClearKey = false
            }
        }, message: {
                Text(L10n.deleteAlbumForever)

        })
        .alert(L10n.deletionError, isPresented: $viewModel.showDeleteActionError, actions: {
            Button(L10n.ok) {
                viewModel.showDeleteActionError = false
            }
        }, message: {
            Text(viewModel.deleteActionError)
        })
        .toolbar(.hidden)
        .ignoresSafeArea(edges: .top)

    }
}

struct AlbumDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {

            AlbumDetailView(viewModel: AlbumDetailViewModel(albumManager: DemoAlbumManager(), key: DemoPrivateKey.dummyKey(), album: Album(name: "Test", storageOption: .local, creationDate: Date())))
        }
    }
}
