//
//  KeyGeneration.swift
//  Encamera
//
//  Created by Alexander Freas on 14.11.21.
//

import SwiftUI
import EncameraCore

enum KeyGenerationError: Error {
    case missingStorageType
}

class KeyGenerationViewModel: ObservableObject {
    @Published var keyName: String = ""
    @Published var keyManagerError: KeyManagerError?
    @MainActor
    @Published var keySaveError: KeyManagerError?
    @MainActor
    @Published var storageAvailabilities: [StorageAvailabilityModel] = []
    @MainActor
    @Published var keyStorageType: StorageType?
    @Published var generalError: KeyGenerationError?

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
                try keyManager.generateNewKey(name: keyName, storageType: keyStorageType)
                try keyManager.setActiveKey(keyName)
            } else {
                throw KeyGenerationError.missingStorageType
            }
        } catch let keyManagerError as KeyManagerError {
            self.keyManagerError = keyManagerError
            throw keyManagerError
        } catch let generalError as KeyGenerationError {
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

struct KeyGeneration: View {
    @StateObject var viewModel: KeyGenerationViewModel
    @Binding var shouldBeActive: Bool
    @FocusState var isFocused: Bool
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        let lastView: AnyView? = nil
        
        let views = [OnboardingFlowScreen.setupPrivateKey, .dataStorageSetting]
            .reversed().reduce(lastView) { partialResult, screen in
            return viewFor(flow: screen, next: {
                partialResult
            })
        }
        views

    }
    
    func viewModel(for flow: OnboardingFlowScreen) -> OnboardingViewViewModel {
        switch flow {
        
        case .setupPrivateKey:
            return .init(
                title: "New Key",
                subheading: "New Key Subheading",
                image: Image(systemName: "key.fill"),
                bottomButtonTitle: "Next",
                bottomButtonAction: {
                    try viewModel.validateKeyName()
                }) {
                    AnyView(
                        VStack {
                            EncameraTextField("Key Name", text: $viewModel.keyName)
                                .noAutoModification()
                                
                                
                            if let keySaveError = viewModel.keySaveError {
                                Text(keySaveError.displayDescription)
                                    .alertText()
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
                try saveKey()
                throw OnboardingViewError.onboardingEnded
            } content: {
                AnyView(
                    VStack {
                        let binding = Binding<StorageType?> {
                            return viewModel.keyStorageType
                        } set: { type in
                            viewModel.keyStorageType = type
                        }
                        StorageSettingView(viewModel: .init(), keyStorageType: binding)
                        if case .missingStorageType = viewModel.generalError {
                            Text("Select a place to keep media for this key.")
                                .alertText()
                        }
                    }
                    
                )
                
            }
        default:
            fatalError()
        }
    }
    
    func saveKey() throws {
        try viewModel.saveKey()
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
