//
//  MainOnboardingView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI
import LocalAuthentication

class OnboardingStateModel: ObservableObject {
    
    enum OnboardingStateError: Error {
        case keyError(with: Error)
        case errorWithFaceID(Error?)
    }
    
    enum OnboardingKeyError: Error {
        case unhandledError
    }
    
    var password1: String = ""
    var password2: String = ""
    var existingPassword: String = ""
    @Published var passwordState: PasswordValidation?
    @MainActor
    @Published var stateError: OnboardingStateError?
    @Published var existingPasswordCorrect: Bool = false
    var useFaceID: Bool = true
    
    
    private var keyManager: KeyManager
    private var authManager: AuthManager
    private var onboardingManager: OnboardingManager
    
    init(keyManager: KeyManager, authManager: AuthManager, onboardingManager: OnboardingManager) {
        self.keyManager = keyManager
        self.authManager = authManager
        self.onboardingManager = onboardingManager
    }
    
    func validatePassword() -> PasswordValidation {
        let state = keyManager.validatePasswordPair(password1, password2: password2)
        self.passwordState = state
        return state
    }
    
    func savePassword() {
        guard case .valid = keyManager.validatePasswordPair(password1, password2: password2) else {
            return
        }
        do {
            try keyManager.setPassword(password1)
        } catch {
            
        }
    }
    
    func checkExistingPassword() -> Bool {
        do {
            existingPasswordCorrect = try keyManager.checkPassword(existingPassword)
            return existingPasswordCorrect
        } catch {
            print("Problem with existing password", error)
            return false
        }
        
    }
    
    @MainActor
    func passwordExists() -> Bool {
        do {
            return try keyManager.passwordExists()
        } catch let keyError as KeyManagerError {
            guard case .notFound = keyError else {
                
                stateError = OnboardingStateError.keyError(with: OnboardingKeyError.unhandledError)
                print("Unhandled error", keyError)
                return false
            }
            return false
        } catch {
            stateError = OnboardingStateError.keyError(with: OnboardingKeyError.unhandledError)
            return false
        }
    }
    
    func saveState() {
        Task {
            if useFaceID {
                do {
                    try await authManager.authorizeWithFaceID()
                } catch let authError as LAError {
                    await MainActor.run {
                        stateError = .errorWithFaceID(authError)
                    }
                    return
                } catch {
                    await MainActor.run {
                        stateError = .errorWithFaceID(error)
                    }
                    return
                }
            }
            do {
                let savedState = OnboardingState.completed(OnboardingSavedInfo(useBiometricsForAuth: useFaceID, password: password1))
                try onboardingManager.saveOnboardingState(savedState)
            } catch {
                await MainActor.run {
                    stateError = .keyError(with: error)
                }
                return
            }
        }
    }
    
    func canAuthenticateWithBiometrics() -> Bool {
        return authManager.canAuthenticateWithBiometrics
    }
}

struct MainOnboardingView: View {
    
    private enum OnboardingViewTabs: String, Identifiable {
        case intro
        case enterExistingPassword
        case setPassword
        case biometrics
        case finished
        var id: Self { self }
    }
    
    @State var currentSelection = 0
    @StateObject var viewModel: OnboardingStateModel
    
    var body: some View {
        
        let selectionBinding = Binding {
            currentSelection
        } set: { target in
            if canGoTo(tab: target) {
                currentSelection = target
            }
        }
        
        TabView(selection: selectionBinding) {
            OnboardingView(viewModel: .init(title: "Keep your files secure.", subheading: "Encrypt everything, take control of your media", image: Image(systemName: "camera"), bottomButtonTitle: "Next", bottomButtonAction: {
                advanceTab()
            })) {
                
            }.tag(OnboardingViewTabs.intro)
            
            if viewModel.passwordExists() {
                OnboardingView(viewModel: .init(title: "Enter your existing password", subheading: "You have an existing password for this device.", image: Image(systemName: "key.fill"), bottomButtonTitle: "Next", bottomButtonAction: {
                    if viewModel.checkExistingPassword() == true {
                        advanceTab()
                    }
                })) {
                    SecureField("Password", text: $viewModel.existingPassword).passwordField()
                }.tag(OnboardingViewTabs.enterExistingPassword)
            } else {
                OnboardingView(viewModel: .init(title: "Set a password.", subheading: "This allows you to access the app. Store this in a safe place, you cannot recover it later!", image: Image(systemName: "lock.iphone"), bottomButtonTitle: "Set Password", bottomButtonAction: {
                    if viewModel.validatePassword() == .valid {
                        advanceTab()
                    }
                })) {
                    VStack {
                        
                        SecureField("Password", text: $viewModel.password1).passwordField()
                        SecureField("Repeat Password", text: $viewModel.password2).passwordField()
                        Group {
                            switch viewModel.passwordState {
                            case .invalidDifferent:
                                Text("Passwords do not match")
                            case .invalidTooLong:
                                Text("Password is too long, >\(PasswordValidation.maxPasswordLength)")
                            case .invalidTooShort:
                                Text("Password is too short, <\(PasswordValidation.minPasswordLength)")
                            case .valid, .notDetermined, .none:
                                EmptyView()
                            }
                        }
                        
                    }
                }.tag(OnboardingViewTabs.setPassword)
            }
            if viewModel.canAuthenticateWithBiometrics() {
                
                OnboardingView(viewModel: .init(title: "Use Face ID?", subheading: "Quickly and securely gain access to the app.", image: Image(systemName: "faceid"), bottomButtonTitle: "Next", bottomButtonAction: {
                    advanceTab()
                })) {
                    HStack {
                        Toggle("Enable Face ID", isOn: $viewModel.useFaceID)
                    }
                }.tag(OnboardingViewTabs.biometrics)
                
            }
            
            OnboardingView(viewModel: .init(title: "You're all set!", subheading: "", image: Image(systemName: "faceid"), bottomButtonTitle: "Done", bottomButtonAction: {
                
            })) {
            }.tag(OnboardingViewTabs.finished)
            
        }
        .tabViewStyle(PageTabViewStyle())
        .background(Color.black)
    }
    
    private func canGoTo(tab: Int) -> Bool {
        return tab <= currentSelection
    }
    
    private func advanceTab() {
        currentSelection += 1
    }
}

struct MainOnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        MainOnboardingView(viewModel: .init(keyManager: DemoKeyManager(), authManager: AuthManager(), onboardingManager: .init(keyManager: DemoKeyManager())))
    }
}
