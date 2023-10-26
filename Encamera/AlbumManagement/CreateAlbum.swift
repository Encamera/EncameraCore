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
    @Published var keyName: String = ""
    @Published var keyManagerError: KeyManagerError?
    @MainActor
    @Published var keySaveError: KeyManagerError?
    @MainActor
    @Published var storageAvailabilities: [StorageAvailabilityModel] = []
    @MainActor
    @Published var keyStorageType: StorageType?
    @Published var generalError: CreateAlbumError?
    @Published var saveToiCloud = false

    var keyManager: KeyManager

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
        Task {
            await MainActor.run {
                self.keyStorageType = DataStorageUserDefaultsSetting().preselectedStorageSetting?.storageType
            }

        }
    }

        @MainActor
        func saveKey() throws {
            do {
                if let keyStorageType = keyStorageType {
                    let _ = try keyManager.generateNewKey(name: keyName, storageType: keyStorageType, backupToiCloud: saveToiCloud)
                    try keyManager.setActiveKey(keyName)
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
                try keyManager.validateKeyName(name: keyName)

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
                self.keyStorageType = availabilites.filter({
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
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        let lastView: AnyView? = nil
        
        let views = [
            OnboardingFlowScreen.setupPrivateKey,
                .dataStorageSetting
        ]
            .reversed().reduce(lastView) { partialResult, screen in
                return viewFor(flow: screen, next: {
                    partialResult
                })
            }
        views
    }
    
    func onboardingViewModel(for flow: OnboardingFlowScreen) -> OnboardingViewViewModel {
        switch flow {
            
        case .setupPrivateKey:
            return .init(
                title: L10n.newKey,
                subheading: L10n.newKeySubheading,
                image: Image(systemName: "key.fill"),
                bottomButtonTitle: L10n.next,
                bottomButtonAction: {
                    try self.viewModel.validateKeyName()
                }) {_ in
                    AnyView(
                        VStack {
                            EncameraTextField(L10n.keyName, text: $viewModel.keyName)
                                .noAutoModification()
                            
                            
                            if let keySaveError = viewModel.keySaveError {
                                Text(keySaveError.displayDescription)
                                    .alertText()
                            }
                        }
                    )
                }
        case .dataStorageSetting:
            
            return .init(title: L10n.storageSettings,
                         subheading: L10n.storageSettingsSubheading,
                         image: Image(systemName: ""),
                         bottomButtonTitle: L10n.saveKey) {
                try saveKey()
                throw OnboardingViewError.onboardingEnded
            } content: {_ in 
                AnyView(
                    VStack {
                        let binding = Binding<StorageType?> {
                            return viewModel.keyStorageType
                        } set: { type in
                            viewModel.keyStorageType = type
                        }
                        StorageSettingView(viewModel: .init(), keyStorageType: binding)
                        if case .missingStorageType = viewModel.generalError {
                            Text(L10n.selectAPlaceToKeepMediaForThisKey)
                                .alertText()
                        }
                        Group {
                            Toggle(L10n.saveKeyToICloud, isOn: $viewModel.saveToiCloud)
                            Text(L10n.ifYouDonTUseICloudBackupItSHighlyRecommendedThatYouBackupYourKeysToAPasswordManagerOrSomewhereElseSafe)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fontType(.pt18)

                    }
                    
                )
                
            }
        default:
            fatalError()
        }
    }
    
    func saveKey() throws {
        try self.viewModel.saveKey()
        dismiss()
    }
    
    @ViewBuilder private func viewFor<Next: View>(flow: OnboardingFlowScreen, next: @escaping () -> Next) -> AnyView {
        AnyView(OnboardingView(
            viewModel: onboardingViewModel(for: flow), nextScreen: {
                next()
            })
        )
    }
}


struct CreateAlbum_Previews: PreviewProvider {
    static var previews: some View {
        CreateAlbum(viewModel: .init(keyManager: DemoKeyManager()))
            .preferredColorScheme(.dark)
    }
}
