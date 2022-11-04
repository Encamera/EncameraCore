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
    case missingStorageType
}

class OnboardingViewModel: ObservableObject {
    
    enum OnboardingKeyError: Error {
        case unhandledError
    }
    
    
    
    @Published var password1: String = ""
    @Published var showPassword = false
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
    @Published var keyStorageType: StorageType?
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
    var keyManager: KeyManager
    private var authManager: AuthManager
    
    
    
    init(onboardingManager: OnboardingManaging, keyManager: KeyManager, authManager: AuthManager) {
        self.onboardingManager = onboardingManager
        self.keyManager = keyManager
        self.authManager = authManager
        onboardingFlow = onboardingManager.generateOnboardingFlow()
        Task {
            await MainActor.run {
                self.keyStorageType = DataStorageUserDefaultsSetting().preselectedStorageSetting?.storageType
            }
        }
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
    func validateStorageSelection() throws {
        
        if keyStorageType == nil {
            try handle(error: OnboardingViewError.missingStorageType)
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
    
    func saveState() async throws {
        
        do {
            let savedState = OnboardingState.completed
            if existingPassword.isEmpty == false {
                try authManager.authorize(with: existingPassword, using: keyManager)
            } else if let storageType = await keyStorageType {
                try authManager.authorize(with: password1, using: keyManager)
                try keyManager.generateNewKey(name: AppConstants.defaultKeyName, storageType: storageType)
            }
            try await onboardingManager.saveOnboardingState(savedState, settings: SavedSettings(useBiometricsForAuth: await useBiometrics))
            
        } catch {
            try await handle(error: error)
        }
    }
}

struct MainOnboardingView: View {
    
    
    @FocusState var password2Focused
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
                title: "Take back your media",
                subheading: """
                            Encamera encrypts all the media it creates.\n
                            Take back control of what is rightfully yours, your privacy,
                            with Encamera.\n
                            Your media, once encrypted, stays away from the prying eyes
                            of AI, media analysis, and other violations of privacy.\n
                            Take pictures knowing that they are for **your eyes only**,
                            not to be fed into some machine learning algorithm for training AI.
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
                            PasswordEntry(viewModel: .init(keyManager: viewModel.keyManager, passwordBinding: $viewModel.existingPassword, stateUpdate: { state in
                                guard case .valid(let existingPassword) = state else {
                                    return
                                }
                                viewModel.existingPassword = existingPassword
                                try? viewModel.checkExistingPasswordAndAuth()
                            }))
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
                    AnyView(
                        VStack(alignment: .leading) {
                            HStack {
                                VStack {
                                    Group {
                                        EncameraTextField("Password", type: viewModel.showPassword ? .normal : .secure, text: $viewModel.password1).onSubmit {
                                            password2Focused = true
                                        }
                                        EncameraTextField("Repeat Password", type: viewModel.showPassword ? .normal : .secure, text: $viewModel.password2)
                                            .focused($password2Focused)
                                            .onSubmit {
                                                password2Focused = false
                                            }
                                    }.noAutoModification()
                                    
                                }
                                Button {
                                    viewModel.showPassword.toggle()
                                } label: {
                                    Image(systemName: viewModel.showPassword ? "eye" : "eye.slash")
                                }
                            }
                            if let passwordState = viewModel.passwordState, passwordState != .valid {
                                Group {
                                    Text(passwordState.validationDescription).alertText()
                                }
                            }
                        })
                    
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
                         bottomButtonTitle: "Next") {
                try viewModel.validateStorageSelection()
            } content: {
                AnyView(
                    VStack {
                        StorageSettingView(viewModel: .init(), keyStorageType: $viewModel.keyStorageType)
                        if case .missingStorageType = viewModel.generalError as? OnboardingViewError {
                            Text("Please select a storage location.")
                                .alertText()
                        }
                    }
                )
                
            }

        case .finished:
            return .init(
                title: "Done!",
                subheading: "All set up! You're now ready to take photos securely with top-notch encryption.",
                image: Image(systemName: "faceid"),
                bottomButtonTitle: "Done",
                bottomButtonAction: {
                    try await viewModel.saveState()
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
                    .fontType(.small)
            }.padding()
        })
        .frame(width: 100, height: 100)
        
        if isSelected.wrappedValue == true {
            output
                .foregroundColor(Color.background)
                .background(background.fill(Color.foregroundPrimary))

        } else {
            output
                .overlay(background.stroke(Color.foregroundSecondary, lineWidth: 3))

        }
    }

}

struct MainOnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        MainOnboardingView(viewModel: .init(onboardingManager: DemoOnboardingManager(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), settingsManager: SettingsManager()), keyManager: DemoKeyManager(), authManager: DemoAuthManager()))
    }
}


