//
//  MainOnboardingView.swift
//  Encamera
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI
import LocalAuthentication

enum OnboardingViewError: Error {
    case passwordInvalid
    case onboardingEnded
}
struct StorageAvailabilityModel: Identifiable {
    let storageType: StorageType
    let availability: StorageType.Availability
    var id: StorageType {
        storageType
    }
}
class OnboardingViewModel: ObservableObject {
    
    enum OnboardingKeyError: Error {
        case unhandledError
    }
    
    
    
    @Published var password1: String = ""
    @Published var password2: String = ""
    @Published var keyName: String = ""
    @Published var existingPassword: String = ""
    var onboardingFlow: [OnboardingFlowScreen]
    @Published var passwordState: PasswordValidation?
    @MainActor
    @Published var stateError: OnboardingManagerError?
    @MainActor
    @Published var keySaveError: KeyManagerError?
    @MainActor
    @Published var generalError: Error?
    @MainActor
    @Published var keyStorageType: StorageType = .local
    @MainActor
    @Published var storageAvailabilities: [StorageAvailabilityModel] = []
    @Published var existingPasswordCorrect: Bool?
    @MainActor
    @Published var useBiometrics: Bool = false {
        didSet {
            guard useBiometrics == true else {
                return
            }
            Task {
                await authWithBiometrics()
            }
        }
    }
    
    var availableBiometric: AuthenticationMethod? {
        return authManager.availableBiometric
    }
    
    
    private var onboardingManager: OnboardingManaging
    private var passwordValidator = PasswordValidator()
    private var keyManager: KeyManager
    private var authManager: AuthManager
    
    
    
    init(onboardingManager: OnboardingManaging, keyManager: KeyManager, authManager: AuthManager) {
        self.onboardingManager = onboardingManager
        self.keyManager = keyManager
        self.authManager = authManager
        onboardingFlow = onboardingManager.generateOnboardingFlow()
    }
    
    func validatePassword() -> PasswordValidation {
        let state = passwordValidator.validatePasswordPair(password1, password2: password2)
        self.passwordState = state
        return state
    }
    
    @MainActor
    func authWithBiometrics() async {
        do {
            try await authManager.evaluateWithBiometrics()
        } catch let authError as AuthManagerError {
            switch authError {
                
            case .passwordIncorrect:
                break
            case .biometricsFailed:
                
                    generalError = authError
                
            case .biometricsNotAvailable, .userCancelledBiometrics:
                
                useBiometrics = false
            }
        } catch {
            generalError = error
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
        case let managerError as OnboardingManagerError:
            stateError = managerError
        case let keyError as KeyManagerError:
            keySaveError = keyError
        default:
            generalError = error
        }
        throw error
    }
    
    @MainActor func savePassword() throws {
        do {
            let validation = validatePassword()
            if validation == .valid {
                try keyManager.setPassword(password1)
            } else {
                throw OnboardingViewError.passwordInvalid
            }
        } catch {
            try handle(error: error)
        }
    }
    
    func checkExistingPasswordAndAuth() throws {
        
        existingPasswordCorrect = try keyManager.checkPassword(existingPassword)
        if existingPasswordCorrect == false {
            throw OnboardingViewError.passwordInvalid
        }
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
    
    func saveState() {
        Task {
            
            do {
                let savedState = OnboardingState.completed
                if existingPassword.isEmpty == false {
                    try authManager.authorize(with: existingPassword, using: keyManager)
                } else {
                    try authManager.authorize(with: password1, using: keyManager)
                }
                try keyManager.generateNewKey(name: keyName, storageType: await keyStorageType)
                try await onboardingManager.saveOnboardingState(savedState, settings: SavedSettings(useBiometricsForAuth: await useBiometrics))
                
            } catch {
                try await handle(error: error)
            }
        }
    }
}

struct MainOnboardingView: View {
    
    
    
    @State var currentSelection = OnboardingFlowScreen.intro
    @StateObject var viewModel: OnboardingViewModel
    
    var body: some View {
        NavigationView {
            buildOnboarding()
        }.ignoresSafeArea(.keyboard)

    }
    
    
    
    private func canGoTo(tab: OnboardingFlowScreen) -> Bool {
        if let currentIndex = viewModel.onboardingFlow.firstIndex(of: currentSelection),
           let targetIndex = viewModel.onboardingFlow.firstIndex(of: tab),
           targetIndex < currentIndex {
            return true
        }
        return false
    }
    
}

private extension MainOnboardingView {
    
    @ViewBuilder func viewFor<Next: View>(flow: OnboardingFlowScreen, next: @escaping () -> Next) -> AnyView {
        AnyView(OnboardingView(
            viewModel: viewModel(for: flow), nextScreen: {
                next()
            })
        )
    }
    
    func buildOnboarding() -> some View {
        
        let lastView: AnyView? = nil
        
        let views = viewModel.onboardingFlow.reversed().reduce(lastView) { partialResult, screen in
            return viewFor(flow: screen, next: {
                partialResult
            })
        }
        return views
    }
    
    func viewModel(for flow: OnboardingFlowScreen) -> OnboardingViewViewModel {
        switch flow {
        case .intro:
            return .init(
                title: "Welcome!",
                subheading: """
                                            Thank you for downloading Encamera.\n
                                            Encamera encrypts every photo it takes,
                                            preventing your most sensitive and private
                                            media from being leaked or hacked.\n
                                            
                                            """,
                             
                image: Image(systemName: "camera"),
                bottomButtonTitle: "Next")
            
        case .enterExistingPassword:
            return .init(
                title: "Enter Password",
                subheading: "You have an existing password for this device.", image: Image(systemName: "key.fill"), bottomButtonTitle: "Next", bottomButtonAction: {
                    try viewModel.checkExistingPasswordAndAuth()
                }) {
                    AnyView(
                        VStack {
                            SecureField("Password", text: $viewModel.existingPassword).passwordField()
                            if let existingPasswordCorrect = viewModel.existingPasswordCorrect, existingPasswordCorrect == false {
                                Group {
                                    Text("Incorrect password").alertText()
                                }
                            }
                        }
                    )
                }
        case .setPassword:
            return .init(
                title: "Set Password",
                subheading: "This allows you to access the app. Store this in a safe place, you cannot recover it later!",
                image: Image(systemName: "lock.iphone"),
                bottomButtonTitle: "Set Password",
                bottomButtonAction: {
                    try viewModel.savePassword()
                }) {
                    AnyView(VStack {
                        SecureField("Password", text: $viewModel.password1).passwordField()
                        SecureField("Repeat Password", text: $viewModel.password2).passwordField()
                        if let passwordState = viewModel.passwordState, passwordState != .valid {
                            Group {
                                Text(passwordState.validationDescription).alertText()
                            }
                        }})
                    
                }
        case .biometrics:
            guard let method = viewModel.availableBiometric else {
                return viewModel(for: .finished)
            }
            return .init(
                title: "Use \(method.nameForMethod)?",
                subheading: "Quickly and securely gain access to the app.",
                image: Image(systemName: method.imageNameForMethod),
                bottomButtonTitle: "Next", content:  {
                    AnyView(Group {HStack {
                        Toggle("Enable \(method.nameForMethod)", isOn: $viewModel.useBiometrics)
                    }})
                })
        case .setupPrivateKey:
            return .init(
                title: "Encryption Key",
                subheading:
                                            """
Set the name for the first key.

This is different from your password, and will be used to encrypt data.

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
                         bottomButtonTitle: "Next") {
            } content: {
                AnyView(
                    StorageSettingView(keyStorageType: $viewModel.keyStorageType, storageAvailabilities: $viewModel.storageAvailabilities)
                    .onAppear {
                        viewModel.loadStorageAvailabilities()
                    }
                )
                
            }

        case .finished:
            return .init(
                title: "Done!",
                subheading: "All set up! Your captured media is now protected with top-notch encryption.",
                image: Image(systemName: "faceid"),
                bottomButtonTitle: "Done",
                bottomButtonAction: {
                    viewModel.saveState()
                    throw OnboardingViewError.onboardingEnded
                })
        }
    }
    
    @ViewBuilder func storageButton(imageName: String, text: String, isSelected: Binding<Bool>, action: @escaping () -> Void) -> some View {
        let background = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let output = Button(action: {
            isSelected.wrappedValue = true
            action()
        }, label: {
            
            VStack {
                Image(systemName: imageName).resizable()
                    .aspectRatio(contentMode: .fit)
                
                Text(text)
            }.padding()
        })
        .frame(width: 100, height: 100)
        
        if isSelected.wrappedValue == true {
            output
                .foregroundColor(Color.black)
                .background(background.fill(Color.white))

        } else {
            output
                .overlay(background.stroke(Color.gray, lineWidth: 3))

        }
    }

}

struct MainOnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        MainOnboardingView(viewModel: .init(onboardingManager: DemoOnboardingManager(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), settingsManager: SettingsManager()), keyManager: DemoKeyManager(), authManager: DemoAuthManager()))
    }
}


