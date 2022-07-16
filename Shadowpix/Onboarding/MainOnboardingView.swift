//
//  MainOnboardingView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI
import LocalAuthentication

class OnboardingStateModel: ObservableObject {
    
    enum OnboardingKeyError: Error {
        case unhandledError
    }
    
    var password1: String = ""
    var password2: String = ""
    var existingPassword: String = ""
    var onboardingFlow: [OnboardingFlowScreen] {
        onboardingManager.generateOnboardingFlow()
    }
    @Published var passwordState: PasswordValidation?
    @MainActor
    @Published var stateError: OnboardingManagerError?
    @Published var existingPasswordCorrect: Bool = false
    var useFaceID: Bool = true
    
    
    private var onboardingManager: OnboardingManager
    private var passwordValidator = PasswordValidator()
    private var keyManager: KeyManager
    
    init(onboardingManager: OnboardingManager, keyManager: KeyManager) {
        self.onboardingManager = onboardingManager
        self.keyManager = keyManager
    }
    
    func validatePassword() -> PasswordValidation {
        let state = passwordValidator.validatePasswordPair(password1, password2: password2)
        self.passwordState = state
        return state
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
            let state = try onboardingManager.getOnboardingState()
            return state == .hasPasswordAndNotOnboarded ? true : false
        } catch let managerError as OnboardingManagerError {
            stateError = managerError
            return false
        } catch {
            return false
        }
        
    }
    
    func saveState() {
        Task {
            
            do {
                let savedState = OnboardingState.completed(OnboardingSavedInfo(useBiometricsForAuth: useFaceID, password: password1))
                try await onboardingManager.saveOnboardingState(savedState)
            } catch let managerError as OnboardingManagerError {
                await MainActor.run {
                    stateError = managerError
                }
                return
            } catch {
                return
            }
        }
    }
}

struct MainOnboardingView: View {
    
    
    
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
            ForEach(viewModel.onboardingFlow) { flow in
                switch flow {
                case .intro:
                    OnboardingView(viewModel: .init(title: "Keep your files secure.", subheading: "Encrypt everything, take control of your media", image: Image(systemName: "camera"), bottomButtonTitle: "Next", bottomButtonAction: {
                        advanceTab()
                    })) {
                        
                    }.tag(flow)

                case .enterExistingPassword:
                    OnboardingView(viewModel: .init(title: "Enter your existing password", subheading: "You have an existing password for this device.", image: Image(systemName: "key.fill"), bottomButtonTitle: "Next", bottomButtonAction: {
                        if viewModel.checkExistingPassword() == true {
                            advanceTab()
                        }
                    })) {
                        SecureField("Password", text: $viewModel.existingPassword).passwordField()
                    }.tag(flow)

                case .setPassword:
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
                    }.tag(flow)
                case .biometrics:
                    OnboardingView(viewModel: .init(title: "Use Face ID?", subheading: "Quickly and securely gain access to the app.", image: Image(systemName: "faceid"), bottomButtonTitle: "Next", bottomButtonAction: {
                        advanceTab()
                    })) {
                        HStack {
                            Toggle("Enable Face ID", isOn: $viewModel.useFaceID)
                        }
                    }.tag(flow)
                case .finished:
                    OnboardingView(viewModel: .init(title: "You're all set!", subheading: "", image: Image(systemName: "faceid"), bottomButtonTitle: "Done", bottomButtonAction: {
                        
                    })) {
                    }.tag(flow)
                }
            }
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

//struct MainOnboardingView_Previews: PreviewProvider {
//    static var previews: some View {
//        MainOnboardingView(viewModel: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), onboardingManager: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager())))
//    }
//}


