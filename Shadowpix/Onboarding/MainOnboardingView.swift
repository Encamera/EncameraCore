//
//  MainOnboardingView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI

class OnboardingState: ObservableObject {
    
    var password1: String = ""
    var password2: String = ""
    @Published var passwordState: PasswordValidation?
//    var storeLocally: Bool = false
    var useFaceID: Bool = true
    
    private var keyManager: KeyManager
    
    init(keyManager: KeyManager) {
        self.keyManager = keyManager
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
}

struct MainOnboardingView: View {
    
    @State var currentSelection = 0
    @StateObject var viewModel: OnboardingState
    
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
                    
                }.tag(0)

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
                }.tag(1)
                OnboardingView(viewModel: .init(title: "Use Face ID?", subheading: "Quickly and securely gain access to the app.", image: Image(systemName: "faceid"), bottomButtonTitle: "Next", bottomButtonAction: {
                    advanceTab()
                })) {
                    HStack {
                        Toggle("Enable Face ID", isOn: $viewModel.useFaceID)
                    }
                }.tag(2)
                OnboardingView(viewModel: .init(title: "You're all set!", subheading: "", image: Image(systemName: "faceid"), bottomButtonTitle: "Done", bottomButtonAction: {
                    
                })) {
                }.tag(3)
                
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
        MainOnboardingView(viewModel: .init(keyManager: DemoKeyManager()))
    }
}
