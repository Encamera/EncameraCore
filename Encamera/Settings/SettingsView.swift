//
//  SettingsView.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import SwiftUI
import Combine

private enum SettingsViewMessage: String {
    case changePasswordSuccess = "Password successfully changed"
    
    
}

class SettingsViewViewModel: ObservableObject {
    
    
    @Published var currentPassword: String = ""
    @Published var newPassword1: String = ""
    @Published var newPassword2: String = ""
    @Published var passwordState: PasswordValidation?
    @Published var keyManagerError: KeyManagerError?
    @Published var showDetailView: Bool = false
    @Published var readyToErase: Bool = false
    @Published var showPromptToErase: Bool = false
    @Published fileprivate var successMessage: SettingsViewMessage?
    var keyManager: KeyManager
    private var cancellables = Set<AnyCancellable>()
    private var passwordValidator = PasswordValidator()
    
    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }
    func resetPasswordInputs() {
        keyManagerError = nil
        passwordState = nil
        newPassword1 = ""
        newPassword2 = ""
        currentPassword = ""
    }
    func savePassword() {
        do {
            self.keyManagerError = nil
            self.passwordState = nil
            let _ = try keyManager.checkPassword(currentPassword)
            let passwordState =  passwordValidator.validatePasswordPair(newPassword1, password2: newPassword2)
            guard case .valid = passwordState else {
                self.passwordState = passwordState
                return
            }
            try keyManager.changePassword(newPassword: newPassword1, existingPassword: currentPassword)
            Just(false).delay(for: .seconds(1), scheduler: RunLoop.main)
                .sink { _ in
                    self.showDetailView = false
                    self.successMessage = nil
                }.store(in: &cancellables)
            self.successMessage = .changePasswordSuccess
            resetPasswordInputs()
        } catch let keyManagerError as KeyManagerError {
            self.keyManagerError = keyManagerError
        } catch {
            print("Change password failed: ", error)
        }
    }
    
    func eraseKeychainData() {
        
    }
    
    func eraseAllData() {
        
    }
    
}

struct SettingsView: View {
    
    
    @Environment(\.dismiss) var dismiss

    @StateObject var viewModel: SettingsViewViewModel
    
    init(viewModel: SettingsViewViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    
    var body: some View {
        Form {
            
            Section {
                changePassword
                reset
            }
            .navigationTitle("Settings")
        }
    }
    
    private var reset: some View {
        NavigationLink("Erase") {
            Form {
                
                Button("Erase keychain data") {
                    
                }
                Button("Erase all data") {
                    
                }
            }
            .foregroundColor(.red)
            .navigationTitle("Erase")
        }
        .sheet(isPresented: $viewModel.showPromptToErase) {
            promptToErase
        }
    }
    
    private var promptToErase: some View {
        return EmptyView()
    }
    
    private var changePassword: some View {
        NavigationLink("Change Password", isActive: $viewModel.showDetailView) {
            Form {
                
                SecureField("Current Password", text: $viewModel.currentPassword)
                if let keyManagerError = viewModel.keyManagerError {
                    Text(keyManagerError.displayDescription).foregroundColor(.red)

                }
                SecureField("New Password", text: $viewModel.newPassword1)
                SecureField("Repeat Password", text: $viewModel.newPassword2)
                if let validation = viewModel.passwordState {
                    Text(validation.validationDescription).foregroundColor(.red)
                }
                if let message = viewModel.successMessage {
                    Text(message.rawValue).foregroundColor(.green)
                }
                
            }
            .toolbar {
                Button("Save") {
                    viewModel.savePassword()
                }
            }
            .navigationTitle("Change Password")
            .onDisappear {
                viewModel.resetPasswordInputs()
            }
        }

    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SettingsView(viewModel: .init(keyManager: DemoKeyManager()))
        }
        
    }
}
