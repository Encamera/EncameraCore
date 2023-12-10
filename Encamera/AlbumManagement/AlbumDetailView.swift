//
//  KeyPickerView.swift
//  encamera
//
//  Created by Alexander Freas on 09.11.21.
//

import SwiftUI
import EncameraCore
import Combine
import SwiftUIIntrospect

import SwiftUI

struct FirstResponderTextFieldModifier: ViewModifier {
    @Binding var isFirstResponder: Bool

    func body(content: Content) -> some View {
        content
            .introspect(.textField) { (textField: UITextField) in
                if self.isFirstResponder {
                    textField.becomeFirstResponder()
                }
            }
    }
}

@MainActor
class AlbumDetailViewModel: ObservableObject {

    enum KeyViewerError {
        case couldNotSetKeychain
    }
    var albumManager: AlbumManaging

    @Published var keyViewerError: KeyViewerError?
    @Published var deleteAlbumConfirmation: String = ""
    @Published var deleteActionError: String = ""
    @Published var showDeleteActionError = false
    @Published var isEditingAlbumName = false
    @Published var albumName: String = ""
    @Published var albumManagerError: String?
    var gridViewModel: GalleryGridViewModel<EncryptedMedia>?

    var purchasedPermissions: PurchasedPermissionManaging = AppPurchasedPermissionUtils()
    var fileManager: FileAccess?
    var key: PrivateKey
    var album: Album? {
        didSet {
            guard let album = album else { return }
            self.albumName = album.name
            self.gridViewModel?.album = album
        }
    }
    var shouldCreateAlbum: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init(albumManager: AlbumManaging, fileManager: FileAccess? = nil, key: PrivateKey, album: Album?, shouldCreateAlbum: Bool = false) {
        self.albumManager = albumManager
        self.fileManager = fileManager
        self.key = key
        self.shouldCreateAlbum = shouldCreateAlbum
        self.isEditingAlbumName = shouldCreateAlbum
        self.gridViewModel = GalleryGridViewModel<EncryptedMedia>(privateKey: key, album: album, albumManager: albumManager, blurImages: false)

        guard let album else { return }
        self.album = album
        self.albumName = album.name

        Task {
            self.fileManager = await DiskFileAccess(for: album, with: key, albumManager: albumManager)
        }
    }


    func renameAlbum() {
        guard albumName.count > 0 else {
            albumManagerError = L10n.pleaseEnterAnAlbumName
            return
        }
        do {

            if shouldCreateAlbum {
                album = try albumManager.create(name: albumName, storageOption: .local)
            } else if let album {
                self.album = try albumManager.renameAlbum(album: album, to: albumName)
            }
        } catch {
            if let albumError = error as? AlbumError, albumError == AlbumError.albumExists {
                albumManagerError = L10n.albumExistsError
            } else {
                albumManagerError = L10n.couldNotRenameAlbumError
            }
        }
        isEditingAlbumName = false
    }

    func deleteAlbum() {
        guard let album else { return }
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
    @State var isShowingMoveAlbumModal = false
    @State var isShowingAlertForCopyKey: Bool = false
    @State var isShowingPurchaseSheet = false
    @StateObject var viewModel: AlbumDetailViewModel

    @Environment(\.dismiss) private var dismiss

    private struct Constants {
        static var outerPadding = 20.0
    }

    var body: some View {
        let _ = Self._printChanges()

        ZStack {
            if let gridViewModel = viewModel.gridViewModel {
                GalleryGridView(viewModel: gridViewModel) {
                    ZStack(alignment: .leading) {

                        Color.inputFieldBackgroundColor
                            .frame(height:230)

                        VStack(alignment: .leading, spacing: 0) {
                            Spacer().frame(height: getSafeAreaTop() / 2)
                            HStack(alignment: .center) {
                                Button {
                                    dismiss()
                                } label: {
                                    Image("Album-BackButton")
                                }
                                .frame(width: 44, height: 44)
                                Spacer()
                                if viewModel.isEditingAlbumName {
                                    Button {
                                        viewModel.renameAlbum()
                                    } label: {
                                        Text(L10n.done)
                                            .fontType(.pt14, on: .textButton, weight: .bold)
                                    }
                                } else {
                                    Menu {
                                        Button(L10n.viewInFiles) {
                                            guard let album = viewModel.album else { return }
                                            LocalDeeplinkingUtils.openAlbumContentsInFiles(albumManager: viewModel.albumManager, album: album)
                                        }
                                        Button(L10n.moveAlbumStorage) {
                                            isShowingMoveAlbumModal = true
                                        }
                                        Button(L10n.rename) {
                                            viewModel.isEditingAlbumName = true
                                        }
                                        Button(L10n.deleteAlbum, role: .destructive) {
                                            isShowingAlertForDeleteAllAlbumData = true
                                        }
                                    } label: {
                                        Image("Album-OptionsDots")
                                    }
                                    .id(UUID())
                                    .frame(width: 44, height: 44)
                                }
                            }.padding(.trailing, 17)
                            VStack(alignment: .leading, spacing: 0) {
                                Spacer().frame(height: 24)
                                if viewModel.isEditingAlbumName {
                                    TextField(L10n.albumName, text: $viewModel.albumName)
                                        .introspect(.textField, on: .iOS(.v13, .v14, .v15, .v16, .v17)) { (textField: UITextField) in
                                            textField.becomeFirstResponder()
                                        }
                                        .fontType(.pt24, weight: .bold)
                                        .noAutoModification()

                                } else {
                                    Text(viewModel.albumName)
                                        .fontType(.pt24, weight: .bold)
                                }
                                Spacer().frame(height: 8)
                                Text(viewModel.album?.creationDate.formatted() ?? "")
                                    .fontType(.pt14)
                                    .opacity(viewModel.isEditingAlbumName ? 0 : 1)

                                Spacer().frame(height: 24)
                                //                            Button {
                                //
                                //                            } label: {
                                //                                Text(L10n.addPhotos)
                                //                                    .fontType(.pt14, on: .textButton, weight: .bold)
                                //                            }
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
                .onAppear {
                    EventTracking.trackAlbumOpened()
                }
                .toolbar(.hidden)
                .ignoresSafeArea(edges: .top)
            } else {
                EmptyView()
            }
                if isShowingMoveAlbumModal, let album = viewModel.album {
                    let hasEntitlement = viewModel.purchasedPermissions.hasEntitlement()
                    ChooseStorageModal(hasEntitlement: hasEntitlement, selectedStorage: album.storageOption) { storage in
                        if hasEntitlement || storage == .local {
                            isShowingMoveAlbumModal = false
                            try? viewModel.albumManager.moveAlbum(album: album, toStorage: storage)
                            EventTracking.trackConfirmStorageTypeSelected(type: storage)
                        } else if !hasEntitlement && storage == .icloud {
                            isShowingPurchaseSheet = true
                        }

                    }
                }
                if isShowingPurchaseSheet {
                    ProductStoreView(fromView: "AlbumDetailView") { action in
                        if case .purchaseComplete = action {
                            isShowingPurchaseSheet = false
                            isShowingMoveAlbumModal = false
                        } else {
                            isShowingPurchaseSheet = false
                        }
                    }
                }
            }


    }
}

//struct AlbumDetailView_Previews: PreviewProvider {
//    static var previews: some View {
//        NavigationView {
//
//            AlbumDetailView(viewModel: AlbumDetailViewModel(albumManager: DemoAlbumManager(), key: DemoPrivateKey.dummyKey(), album: Album(name: "Test", storageOption: .local, creationDate: Date(), key: DemoPrivateKey.dummyKey())))
//        }
//    }
//}
