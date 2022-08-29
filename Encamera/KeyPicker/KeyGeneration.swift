//
//  KeyGeneration.swift
//  Encamera
//
//  Created by Alexander Freas on 14.11.21.
//

import SwiftUI

class KeyGenerationViewModel: ObservableObject {
    @Published var keyName: String = ""
    @Published var keyManagerError: KeyManagerError?
    @MainActor
    @Published var keySaveError: KeyManagerError?
    @MainActor
    @Published var storageAvailabilities: [StorageAvailabilityModel] = []
    @MainActor
    @Published var keyStorageType: StorageType = .local

    var keyManager: KeyManager
    
    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }
    
    @MainActor
    func saveKey() {
        do {
            try keyManager.generateNewKey(name: keyName, storageType: keyStorageType)
        } catch {
            guard let keyError = error as? KeyManagerError else {
                return
            }
            self.keyManagerError = keyError
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
    
    func loadStorageAvailabilities() {
        Task {
            var availabilites = [StorageAvailabilityModel]()
            for type in StorageType.allCases {
                let result = await keyManager.keyDirectoryStorage.isStorageTypeAvailable(type: type)
                availabilites += [StorageAvailabilityModel(storageType: type, availability: result)]
            }
            await setStorage(availabilites: availabilites)
        }
        
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

struct KeyGeneration: View {
    @StateObject var viewModel: KeyGenerationViewModel
    @Binding var shouldBeActive: Bool
    @FocusState var isFocused: Bool
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        let lastView: AnyView? = nil
        
        let views = [OnboardingFlowScreen.setupImageKey, .dataStorageSetting]
            .reversed().reduce(lastView) { partialResult, screen in
            return viewFor(flow: screen, next: {
                partialResult
            })
        }
        views

    }
    
    func viewModel(for flow: OnboardingFlowScreen) -> OnboardingViewViewModel {
        switch flow {
        
        case .setupImageKey:
            return .init(
                title: "Setup Image Key",
                subheading:
                                            """
Set the name for this key.

You can have multiple keys for different purposes, e.g. one named "Documents" and another "Personal".
""",
                image: Image(systemName: "key.fill"),
                bottomButtonTitle: "Next",
                bottomButtonAction: {
                    try viewModel.validateKeyName()
                }) {
                    AnyView(
                        VStack {
                            TextField("Name", text: $viewModel.keyName)
                                .inputTextField()
                                .textCase(.lowercase)
                                .disableAutocorrection(true)
                                .textInputAutocapitalization(.never)
                                
                            if let keySaveError = viewModel.keySaveError {
                                Group {
                                    Text(keySaveError.displayDescription)
                                }.foregroundColor(.red)
                            }
                        }
                    )
                }
        case .dataStorageSetting:


            return .init(title: "Storage Settings",
                         subheading: """
Where do you want to store media for files encrypted with this key?

Each key will store data in its own directory.
""",
                         image: Image(systemName: ""),
                         bottomButtonTitle: "Save Key") {
                saveKey()
                throw OnboardingViewError.onboardingEnded
            } content: {
                AnyView(
                    StorageSettingView(keyStorageType: $viewModel.keyStorageType, storageAvailabilities: $viewModel.storageAvailabilities)
                    .onAppear {
                        viewModel.loadStorageAvailabilities()
                    }
                )
                
            }
        default:
            fatalError()
        }
    }
    
    func saveKey() {
        viewModel.saveKey()
        shouldBeActive = false
    }
    
    @ViewBuilder private func viewFor<Next: View>(flow: OnboardingFlowScreen, next: @escaping () -> Next) -> AnyView {
        AnyView(OnboardingView(
            viewModel: viewModel(for: flow), nextScreen: {
                next()
            })
        )
    }
}

//struct KeyGeneration_Previews: PreviewProvider {
//    static var previews: some View {
//        KeyGeneration(viewModel: .init(keyManager: DemoKeyManager()), shouldBeActive: false)
//    }
//}
