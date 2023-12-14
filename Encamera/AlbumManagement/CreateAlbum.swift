//
//  CreateAlbum.swift
//  Encamera
//
//  Created by Alexander Freas on 14.11.21.
//

import SwiftUI
import EncameraCore

enum CreateAlbumError: Error {
    case missingStorageType
}

class CreateAlbumViewModel: ObservableObject {
    @Published var albumName: String = ""
    @Published var keyManagerError: KeyManagerError?
    @MainActor
    @Published var keySaveError: KeyManagerError?
    @MainActor
    @Published var storageAvailabilities: [StorageAvailabilityModel] = []
    @MainActor
    @Published var albumStorageType: StorageType?
    @Published var generalError: CreateAlbumError?
    @Published var saveToiCloud = false

    var albumManager: AlbumManaging

    init(albumManager: AlbumManaging) {
        self.albumManager = albumManager
        Task {
            await MainActor.run {
                self.albumStorageType = albumManager.defaultStorageForAlbum
            }

        }
    }

        @MainActor
        func saveAlbum() throws {
            do {
                if let albumStorageType {
                    EventTracking.trackAlbumCreated()
                    try albumManager.create(name: albumName, storageOption: albumStorageType)
                } else {
                    throw CreateAlbumError.missingStorageType
                }
            } catch let keyManagerError as KeyManagerError {
                self.keyManagerError = keyManagerError
                throw keyManagerError
            } catch let generalError as CreateAlbumError {
                self.generalError = generalError
                throw generalError
            } catch {
                print("Unhandled error", error)
                throw error
            }

        }

        @MainActor
        func validateKeyName() throws {
            do {
                try albumManager.validateAlbumName(name: albumName)

            } catch {
                try handle(error: error)
            }
        }

        @MainActor
        func handle(error: Error) throws {
            switch error {
            case let keyError as KeyManagerError:
                keySaveError = keyError
            default:
                throw error
            }
            throw error
        }

        @MainActor
        func setStorage(availabilites: [StorageAvailabilityModel]) async {
            await MainActor.run {
                self.albumStorageType = availabilites.filter({
                    if case .available = $0.availability {
                        return true
                    }
                    return false
                }).map({$0.storageType}).first ?? .local
                self.storageAvailabilities = availabilites
            }
        }

}

struct CreateAlbum: View {
    @StateObject var viewModel: CreateAlbumViewModel
    @FocusState var isFocused: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            HeadingSubheadingImageComponent(
                title: L10n.newAlbum, subheading: L10n.newAlbumSubheading, image: Image(systemName: "photo.badge.plus.fill"))
            EncameraTextField(L10n.albumName, text: $viewModel.albumName)
                .noAutoModification()



            if let keySaveError = viewModel.keySaveError {
                Text(keySaveError.displayDescription)
                    .alertText()
            }
            let binding = Binding<StorageType?> {
                return viewModel.albumStorageType
            } set: { type in
                viewModel.albumStorageType = type
            }
            StorageSettingView(viewModel: .init(), keyStorageType: binding)
            if case .missingStorageType = viewModel.generalError {
                Text(L10n.selectAPlaceToKeepMediaForThisKey)
                    .alertText()
            }
            Spacer()
            Button(L10n.createNewAlbum) {
                do {
                    try viewModel.saveAlbum()
                    dismiss()
                } catch {
                    debugPrint("Error saving album", error)
                }
            }.primaryButton()

        }
        .defaultEdgeSpacing()
        .gradientBackground()

    }
    
    func saveAlbum() throws {
        try self.viewModel.saveAlbum()
        dismiss()
    }

}


struct CreateAlbum_Previews: PreviewProvider {
    static var previews: some View {
        CreateAlbum(viewModel: .init(albumManager: DemoAlbumManager()))
            .preferredColorScheme(.dark)
    }
}
