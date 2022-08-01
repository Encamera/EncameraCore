//
//  MainOnboardingView.swift
//  Shadowpix
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
    @Published var existingPassword: String = ""
    var onboardingFlow: [OnboardingFlowScreen]
    @Published var passwordState: PasswordValidation?
    @MainActor
    @Published var stateError: OnboardingManagerError?
    @Published var existingPasswordCorrect: Bool = false
    @Published var useBiometrics: Bool = false
    
    
    private var onboardingManager: OnboardingManager
    private var passwordValidator = PasswordValidator()
    private var keyManager: KeyManager
    
    init(onboardingManager: OnboardingManager, keyManager: KeyManager) {
        self.onboardingManager = onboardingManager
        self.keyManager = keyManager
        onboardingFlow = onboardingManager.generateOnboardingFlow()
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
            debugPrint("Problem with existing password", error)
            return false
        }
        
    }
    
    func saveState() {
        Task {
            
            do {
                let savedState = OnboardingState.completed(SavedSettings(useBiometricsForAuth: useBiometrics, password: !password1.isEmpty))
                try await onboardingManager.saveOnboardingState(savedState, password: password1)
            } catch let managerError as OnboardingManagerError {
                debugPrint("onboarding manager error", managerError)
                await MainActor.run {
                    stateError = managerError
                }
            } catch {
                debugPrint("Error saving state", error)
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
                        OnboardingView(viewModel: .init(title: "Keep your files secure.", subheading: "Encrypt everything, take control of your media", image: Image(systemName: "camera"), bottomButtonTitle: "Next", bottomButtonAction: {
                            advanceTab()
                        })) {
                            
                        }
                        
                    case .enterExistingPassword:
                        OnboardingView(viewModel: .init(title: "Enter your existing password", subheading: "You have an existing password for this device.", image: Image(systemName: "key.fill"), bottomButtonTitle: "Next", bottomButtonAction: {
                            if viewModel.checkExistingPassword() == true {
                                advanceTab()
                            }
                        })) {
                            SecureField("Password", text: $viewModel.existingPassword).passwordField()
                        }
                        
                    case .setPassword:
                        OnboardingView(viewModel: .init(title: "Set a password.", subheading: "This allows you to access the app. Store this in a safe place, you cannot recover it later!", image: Image(systemName: "lock.iphone"), bottomButtonTitle: "Set Password", bottomButtonAction: {
                            if viewModel.validatePassword() == .valid {
                                advanceTab()
                            }
                        })) {
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
                    case .biometrics:
                        OnboardingView(viewModel: .init(title: "Use Face ID?", subheading: "Quickly and securely gain access to the app.", image: Image(systemName: "faceid"), bottomButtonTitle: "Next", bottomButtonAction: {
                            advanceTab()
                        })) {
                            HStack {
                                Toggle("Enable Face ID", isOn: $viewModel.useBiometrics)
                            }
                        }
                    case .finished:
                        OnboardingView(viewModel: .init(title: "You're all set!", subheading: "", image: Image(systemName: "faceid"), bottomButtonTitle: "Done", bottomButtonAction: {
                            viewModel.saveState()
                        })) {
                        }
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

//struct MainOnboardingView_Previews: PreviewProvider {
//    static var previews: some View {
//        MainOnboardingView(viewModel: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), onboardingManager: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager())))
//    }
//}


