//
//  MainOnboardingView.swift
//  Encamera
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI
import LocalAuthentication

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
    @Published var keySaveError: KeyManagerError?
    @Published var generalError: Error?
    @Published var existingPasswordCorrect: Bool = false
    @Published var useBiometrics: Bool = false
    
    
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
    
    
    func saveKey() throws {
        do {
            try keyManager.generateNewKey(name: keyName)
        } catch let keyError as KeyManagerError {
            self.keySaveError = keyError
            throw keyError
        } catch {
            self.generalError = error
            throw error
        }
    }
    
    func savePassword() throws -> Bool {
        let validation = validatePassword()
        if validation == .valid {
            try keyManager.setPassword(password1)
            try authManager.authorize(with: password1, using: keyManager)
            return true
        } else {
            return false
        }
    }
    
    func checkExistingPassword() -> Bool {
        
        do {
            existingPasswordCorrect = try keyManager.checkPassword(existingPassword)
            try authManager.authorize(with: existingPassword, using: keyManager)
            return existingPasswordCorrect
        } catch {
            debugPrint("Problem with existing password", error)
            return false
        }
        
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
        
        let selectionBinding = Binding {
            currentSelection
        } set: { target in
            if canGoTo(tab: target) {
                debugPrint("tab target", target)
                currentSelection = target
            }
        }
        
        TabView(selection: selectionBinding) {
            let _ = debugPrint(selectionBinding.wrappedValue, "selection")
            ForEach(viewModel.onboardingFlow) { flow in
                Group {
                    switch flow {
                    case .intro:
                        introView
                    case .enterExistingPassword:
                        enterExistingPasswordView
                    case .setPassword:
                        setPasswordView
                    case .biometrics:
                        biometricsView
                    case .setupImageKey:
                        setupImageKeyView
                    case .finished:
                        finishedView
                    }
                }.tag(flow)
            }
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .background(Color.black)
    }
    
    private func canGoTo(tab: OnboardingFlowScreen) -> Bool {
        if let currentIndex = viewModel.onboardingFlow.firstIndex(of: currentSelection),
            let targetIndex = viewModel.onboardingFlow.firstIndex(of: tab),
           targetIndex < currentIndex {
            return true
        }
        return false
    }
    
    private func advanceTab() {
        if let currentIndex = viewModel.onboardingFlow.firstIndex(of: currentSelection),
           currentIndex < viewModel.onboardingFlow.count {
            currentSelection = viewModel.onboardingFlow[currentIndex + 1]
        }
    }
    
    
}

private extension MainOnboardingView {
    
    
    
    var introView: some View {
        OnboardingView(viewModel: .init(title: "Keep your files secure.", subheading: "Encrypt everything, take control of your media", image: Image(systemName: "camera"), bottomButtonTitle: "Next", bottomButtonAction: {
            advanceTab()
        }), nextScreen: {
            
        }, content: {
            
        })
    }
    
    var enterExistingPasswordView: some View {
        OnboardingView(viewModel: .init(title: "Enter your existing password", subheading: "You have an existing password for this device.", image: Image(systemName: "key.fill"), bottomButtonTitle: "Next", bottomButtonAction: {
            if viewModel.checkExistingPassword() == true {
                advanceTab()
            }
        }), nextScreen: {
        }, content: {
            SecureField("Password", text: $viewModel.existingPassword).passwordField()

        })

    }
    
    var setPasswordView: some View {
        OnboardingView(viewModel: .init(title: "Set a password.", subheading: "This allows you to access the app. Store this in a safe place, you cannot recover it later!", image: Image(systemName: "lock.iphone"), bottomButtonTitle: "Set Password", bottomButtonAction: {
            
            if try viewModel.savePassword() {
                advanceTab()
            }
        })) {
            
        } content: {
            VStack {
                
                SecureField("Password", text: $viewModel.password1).passwordField()
                SecureField("Repeat Password", text: $viewModel.password2).passwordField()
                if let passwordState = viewModel.passwordState {
                    Group {
                        Text(passwordState.validationDescription)
                    }.foregroundColor(.red)
                }
            }
        }
    }
    
    var biometricsView: some View {
        OnboardingView(viewModel: .init(title: "Use Face ID?", subheading: "Quickly and securely gain access to the app.", image: Image(systemName: "faceid"), bottomButtonTitle: "Next", bottomButtonAction: {
            advanceTab()
        })) {
            
        } content: {
            HStack {
                Toggle("Enable Face ID", isOn: $viewModel.useBiometrics)
            }
        }

    }
    
    var setupImageKeyView: some View {
        OnboardingView(viewModel: .init(title: "Setup Image Key", subheading:
                                            """
Set the name for the first key.

This is different from your password, and will be used to encrypt data.

You can have multiple keys for different purposes, e.g. one named "Banking" and another "Personal".
""", image: Image(systemName: "key.fill"), bottomButtonTitle: "Save Key", bottomButtonAction: {
            try viewModel.saveKey()
            advanceTab()
        })) {
            
        } content: {
            VStack {
                TextField("Name", text: $viewModel.keyName).inputTextField()
                if let keySaveError = viewModel.keySaveError {
                    Group {
                        Text(keySaveError.displayDescription)
                    }.foregroundColor(.red)
                }
            }
        }
    }
    
    var finishedView: some View {
        OnboardingView(viewModel: .init(title: "You're all set!", subheading: "", image: Image(systemName: "faceid"), bottomButtonTitle: "Done", bottomButtonAction: {
            viewModel.saveState()
        })) {
        } content: {
            
        }

    }
}

//struct MainOnboardingView_Previews: PreviewProvider {
//    static var previews: some View {
//        MainOnboardingView(viewModel: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), onboardingManager: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager())))
//    }
//}


