//
//  KeyPickerView.swift
//  encamera
//
//  Created by Alexander Freas on 09.11.21.
//

import Combine
import EncameraCore
import SwiftUI
import SwiftUIIntrospect

import SwiftUI

@MainActor
class AlbumDetailViewModel<D: FileAccess>: ObservableObject {
    enum KeyViewerError {
        case couldNotSetKeychain
    }

    var albumManager: AlbumManaging

    @Published var keyViewerError: KeyViewerError?
    @Published var deleteAlbumConfirmation: String = ""
    @Published var deleteActionError: String = ""
    @Published var isEditingAlbumName = false
    @Published var albumName: String = ""
    @Published var albumManagerError: String?
    @Published var showEmptyView: Bool = false
    @Published var isSelectingMedia: Bool = false
    @Published var selectedMedia: Set<InteractableMedia<EncryptedMedia>> = Set()
    var afterPurchaseAction: (() -> Void)?
    var gridViewModel: GalleryGridViewModel<D>

    var purchasedPermissions: PurchasedPermissionManaging = AppPurchasedPermissionUtils()
    var fileManager: D?
    var album: Album? {
        didSet {
            guard let album = album else { return }
            self.albumName = album.name
            self.gridViewModel.album = album
        }
    }

    var shouldCreateAlbum: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init(albumManager: AlbumManaging, fileManager: D? = nil, album: Album?, shouldCreateAlbum: Bool = false) {
        self.albumManager = albumManager
        self.fileManager = fileManager
        self.shouldCreateAlbum = shouldCreateAlbum
        self.isEditingAlbumName = shouldCreateAlbum
        let gridViewModel = GalleryGridViewModel<D>(album: album, albumManager: albumManager, blurImages: false, fileAccess: fileManager ?? D.init())
        self.gridViewModel = gridViewModel

        self.$isSelectingMedia.sink { isSelecting in
            gridViewModel.isSelectingMedia = isSelecting
        }.store(in: &cancellables)
        gridViewModel.$selectedMedia.sink { selected in
            self.selectedMedia = selected
        }.store(in: &cancellables)

        albumManager.albumOperationPublisher
            .receive(on: RunLoop.main)
            .sink { operation in
                switch operation {
                case .albumMoved(let album), .albumRenamed(let album):
                    Task { @MainActor in
                        self.album = album
                        await self.gridViewModel.enumerateMedia()
                    }
                default: break
                }
            }.store(in: &cancellables)
        guard let album else { return }
        self.album = album
        self.albumName = album.name
        gridViewModel.$showEmptyView.sink { value in
            self.showEmptyView = value
        }.store(in: &cancellables)
        Task {
            self.fileManager = await D(for: album, albumManager: albumManager)
        }
    }

    func renameAlbum() {
        guard albumName.count > 0 else {
            albumManagerError = L10n.pleaseEnterAnAlbumName
            return
        }
        do {
            if shouldCreateAlbum {
                album = try albumManager.create(name: albumName, storageOption: albumManager.defaultStorageForAlbum)
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

    func moveAlbum(to storage: StorageType) {
        guard let album else { return }
        self.album = try? albumManager.moveAlbum(album: album, toStorage: storage)
        EventTracking.trackConfirmStorageTypeSelected(type: storage)
    }

    var currentSharingData: Any?

    @MainActor
    func shareSheet(data: [Any]) {
        self.currentSharingData = data

        let activityView = UIActivityViewController(activityItems: data + [self], applicationActivities: nil)
        activityView.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            if let error = error {
                print("Share error: \(error.localizedDescription)")
            }
            self.currentSharingData = nil
            EventTracking.trackMediaShared()
        }

        let allScenes = UIApplication.shared.connectedScenes
        let scene = allScenes.first { $0.activationState == .foregroundActive }

        if let windowScene = scene as? UIWindowScene {
            windowScene.keyWindow?.rootViewController?.present(activityView, animated: true, completion: nil)
        }
    }

    func shareSelected() {
        selectedMedia.forEach { media in
            fileManager?.loadMedia(media: media) { result in
                switch result {
                case .success(let data):
                    shareSheet(data: [data])
                case .failure(let error):
                    print("Error loading media: \(error)")
                }
            }
        }
    }
}

private enum Constants {
    static var outerPadding = 20.0
}

struct AlbumDetailView<D: FileAccess>: View {
    @State var isShowingAlertForDeleteAllAlbumData: Bool = false
    @State var isShowingMoveAlbumModal = false
    @State var isShowingPurchaseSheet = false

    @StateObject var viewModel: AlbumDetailViewModel<D>
    @Environment(\.presentationMode) private var presentationMode

    func popLastView() {
        presentationMode.wrappedValue.dismiss()
    }



    var body: some View {

        VStack {
            GalleryGridView(viewModel: viewModel.gridViewModel) {
                ZStack(alignment: .leading) {
                    horizontalTitleComponents
                }
            }
            .screenBlocked()
            .alert(L10n.deleteAllAssociatedData, isPresented: $isShowingAlertForDeleteAllAlbumData, actions: {
                Button(L10n.deleteEverything, role: .destructive) {
                    viewModel.deleteAlbum()
                    popLastView()
                }
                Button(L10n.cancel, role: .cancel) {
                    isShowingAlertForDeleteAllAlbumData = false
                }
            }, message: {
                Text(viewModel.deleteActionError)
            })
            .navigationBarHidden(true)
            .chooseStorageModal(isPresented: $isShowingMoveAlbumModal,
                                album: viewModel.album,
                                purchasedPermissions: viewModel.purchasedPermissions, didSelectStorage: { storage, hasEntitlement in
                if hasEntitlement || storage == .local {
                    viewModel.moveAlbum(to: storage)
                    isShowingMoveAlbumModal = false
                } else if !hasEntitlement && storage == .icloud {
                    isShowingPurchaseSheet = true
                    viewModel.afterPurchaseAction = {
                        viewModel.moveAlbum(to: storage)
                    }
                }
            }, dismissAction: {
                isShowingMoveAlbumModal = false
            })
            .productStore(isPresented: $isShowingPurchaseSheet, fromViewName: "AlbumDetailView") { action in
                if case .purchaseComplete = action {
                    isShowingPurchaseSheet = false
                    isShowingMoveAlbumModal = false
                    viewModel.afterPurchaseAction?()
                } else {
                    isShowingPurchaseSheet = false
                }
            }
            if viewModel.isSelectingMedia {
                selectionTray
            }
        }
        .gradientBackground()
        .ignoresSafeArea(edges: [.bottom])
    }

    var horizontalTitleComponents: some View {
        Group {
            if viewModel.isEditingAlbumName {
                ViewHeader(centerContent: {
                    TextField(L10n.albumName, text: $viewModel.albumName)
                        .becomeFirstResponder()
                        .fontType(.pt24, weight: .bold)
                        .noAutoModification()
                }, rightContent: {
                    HStack {
                        Button {
                            viewModel.albumName = viewModel.album?.name ?? ""
                            viewModel.isEditingAlbumName = false
                        } label: {
                            Text(L10n.cancel)
                                .fontType(.pt14, weight: .bold)
                        }.frostedButton()
                        Button {
                            viewModel.renameAlbum()
                            viewModel.isEditingAlbumName = false
                        } label: {
                            Text(L10n.save)
                                .fontType(.pt14, weight: .bold)
                        }.frostedButton()
                    }
                })
            } else {

                ViewHeader(title: viewModel.albumName, rightContent: {
                    Group {
                        Button {
                            viewModel.isSelectingMedia.toggle()
                        } label: {
                            Text(viewModel.isSelectingMedia ? L10n.cancel : L10n.AlbumDetailView.select)
                                .fontType(.pt14, weight: .bold)
                        }.frostedButton()
                        if viewModel.isSelectingMedia == false {
                            VStack(alignment: .center) {
                                buttonMenu
                            }
                        }
                    }
                }, leftContent: {

                    Button {
                        popLastView()
                    } label: {
                        Image("Album-BackButton")
                    }
                }).transition(.slide)
            }
        }
    }

    var buttonMenu: some View {
        Menu {
            Button(L10n.moveAlbumStorage) {
                isShowingMoveAlbumModal = true
            }
            Button(L10n.viewInFiles) {
                LocalDeeplinkingUtils.openAlbumContentsInFiles(albumManager: viewModel.albumManager, album: viewModel.album!)
            }
            Button(L10n.rename) {
                viewModel.isEditingAlbumName = true
            }
            Button(L10n.deleteAlbum, role: .destructive) {
                isShowingAlertForDeleteAllAlbumData = true
            }

        } label: {
            Image("Album-OptionsDots")
                .contentShape(Rectangle())
                .frostedButton()
        }
    }

    var selectionTray: some View {
        MediaSelectionTray(shareAction: {

        }, deleteAction: {

        }, selectedMedia: $viewModel.selectedMedia)

    }


}

extension AlbumDetailView: UIActivityItemSource {
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return "Encamera Media"
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {

    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
    }
}

#Preview {
    //    AlbumDetailView<D>(viewModel: .init(albumManager: viewModel.albumManager, album: album)).onAppear {
    //        EventTracking.trackAlbumOpened()
    //    }

    AlbumDetailView<DemoFileEnumerator>(viewModel: .init(albumManager: DemoAlbumManager(), album: DemoAlbumManager().currentAlbum))
}
