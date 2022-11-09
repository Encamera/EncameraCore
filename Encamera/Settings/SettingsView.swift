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
    @Published var showPremium: Bool = false
    @Published fileprivate var successMessage: SettingsViewMessage?
    var keyManager: KeyManager
    var fileAccess: FileAccess
    private var cancellables = Set<AnyCancellable>()
    private var passwordValidator = PasswordValidator()
    
    init(keyManager: KeyManager, fileAccess: FileAccess) {
        self.keyManager = keyManager
        self.fileAccess = fileAccess
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
            Group {
                Section {
                    Button("✨ Premium ✨") {
                        viewModel.showPremium = true
                    }
                    changePassword
                    reset
                }
                
                .navigationTitle("Settings")
                
                Section("Legal") {
                    Button("Privacy Policy") {
                        guard let url = URL(string: "https://encrypted.camera/privacy") else {
                            return
                        }
                        Task {
                            await UIApplication.shared.open(url)
                        }
                    }
                    Button("Terms of Use") {
                        guard let url = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") else {
                            return
                        }
                        Task {
                            await UIApplication.shared.open(url)
                        }
                    }
                }
            }.listRowBackground(Color.foregroundSecondary)
        }
        .scrollContentBackgroundColor(Color.background)
        .fontType(.small)
        .sheet(isPresented: $viewModel.showPremium) {
            premium
        }
        
        
        
    }
    
    private var premium: some View {
        SubscriptionStoreView(controller: StoreActor.shared.subscriptionController)
    }
    
    private var reset: some View {
        NavigationLink("Erase") {
            Form {
                Group {
                    NavigationLink {
                        PromptToErase(viewModel: .init(scope: .appData, keyManager: viewModel.keyManager, fileAccess: viewModel.fileAccess))
                        
                    } label: {
                        Text("Erase keychain data")
                    }
                    NavigationLink {
                        PromptToErase(viewModel: .init(scope: .allData, keyManager: viewModel.keyManager, fileAccess: viewModel.fileAccess))
                        
                    } label: {
                        Text("Erase all data")
                    }
                }.listRowBackground(Color.foregroundSecondary)
            }
            
            .foregroundColor(.red)
            .navigationTitle("Erase")
            .fontType(.small)
            .scrollContentBackgroundColor(.background)
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
            .scrollContentBackgroundColor(.background)
            .fontType(.small)
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
            SettingsView(viewModel: .init(keyManager: DemoKeyManager(), fileAccess: DemoFileEnumerator()))
        }.preferredColorScheme(.dark)
        
    }
}
