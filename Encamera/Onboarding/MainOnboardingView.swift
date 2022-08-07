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
    @Published var existingPasswordCorrect: Bool = false
    @Published var useBiometrics: Bool = false {
        didSet {
            guard useBiometrics == true else {
                return
            }
            Task {
                try await authManager.authorizeWithFaceID()
            }
        }
    }
    
    
    private var onboardingManager: OnboardingManager
    private var passwordValidator = PasswordValidator()
    private var keyManager: KeyManager
    private var authManager: AuthManager
    
    init(onboardingManager: OnboardingManager, keyManager: KeyManager, authManager: AuthManager) {
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
    func saveKey() throws {
        do {
            try keyManager.generateNewKey(name: keyName, storageType: keyStorageType)
        } catch let keyError as KeyManagerError {
            self.keySaveError = keyError
            throw keyError
        } catch {
            self.generalError = error
            throw error
        }
    }
    
    func savePassword() throws {
        let validation = validatePassword()
        if validation == .valid {
            try keyManager.setPassword(password1)
            try authManager.authorize(with: password1, using: keyManager)
        } else {
            throw OnboardingViewError.passwordInvalid
        }
    }
    
    func checkExistingPasswordAndAuth() throws {
        
        existingPasswordCorrect = try keyManager.checkPassword(existingPassword)
        try authManager.authorize(with: existingPassword, using: keyManager)
        
    }
    
    func saveState() {
        Task {
            
            do {
                let savedState = OnboardingState.completed(SavedSettings(useBiometricsForAuth: useBiometrics))
                try await onboardingManager.saveOnboardingState(savedState)
                if useBiometrics {
                    try await authManager.authorizeWithFaceID()
                } else {
                    try authManager.authorize(with: password1, using: keyManager)
                }
                
            } catch let managerError as OnboardingManagerError {
                debugPrint("onboarding manager error", managerError)
                await MainActor.run {
                    stateError = managerError
                }
            } catch {
                debugPrint("Error saving state", error)
                await MainActor.run {
                    generalError = error
                }
                return
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
        }
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
            }))
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
                title: "Keep your files secure.",
                subheading: "Encrypt everything, take control of your media",
                image: Image(systemName: "camera"),
                bottomButtonTitle: "Next")
            
        case .enterExistingPassword:
            return .init(
                title: "Enter your existing password",
                subheading: "You have an existing password for this device.", image: Image(systemName: "key.fill"), bottomButtonTitle: "Next", bottomButtonAction: {
                    try viewModel.checkExistingPasswordAndAuth()
                }) {
                    AnyView(SecureField("Password", text: $viewModel.existingPassword).passwordField())
                }
        case .setPassword:
            return .init(
                title: "Set a password.",
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
                                Text(passwordState.validationDescription)
                            }.foregroundColor(.red)
                        }})
                    
                }
        case .biometrics:
            return .init(
                title: "Use Face ID?",
                subheading: "Quickly and securely gain access to the app.",
                image: Image(systemName: "faceid"),
                bottomButtonTitle: "Next", content:  {
                    AnyView(Group {HStack {
                        Toggle("Enable Face ID", isOn: $viewModel.useBiometrics)
                    }})
                })
        case .setupImageKey:
            return .init(
                title: "Setup Image Key",
                subheading:
                                            """
Set the name for the first key.

This is different from your password, and will be used to encrypt data.

You can have multiple keys for different purposes, e.g. one named "Banking" and another "Personal".
""",
                image: Image(systemName: "key.fill"),
                bottomButtonTitle: "Save Key",
                bottomButtonAction: {
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
                         subheading: "Where do you want to store media for files encrypted with this key?",
                         image: Image(systemName: ""),
                         bottomButtonTitle: "Next") {
            } content: {
                AnyView(
                 HStack {
                     

                     ForEach(StorageType.allCases) { data in
                         let binding = Binding {
                             data == viewModel.keyStorageType
                         } set: { value in
                             viewModel.keyStorageType = data
                         }
                         storageButton(imageName: data.iconName, text: data.title, isSelected: binding) {
                             
                         }
                     }
                     
                 })}

        case .finished:
            return .init(
                title: "You're all set!",
                subheading: "",
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

//struct MainOnboardingView_Previews: PreviewProvider {
//    static var previews: some View {
//        MainOnboardingView(viewModel: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), onboardingManager: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager())))
//    }
//}


