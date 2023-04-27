//
//  SettingsView.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import SwiftUI
import StoreKit
import Combine
import EncameraCore

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
    @Published fileprivate var successMessage: String?
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
            self.successMessage = L10n.passwordSuccessfullyChanged
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
                    Text("What is Encamera?")
                    Text("About Encryption")
                    Text("Open Source")
                }
                Section {
                    Button(L10n.premiumSparkles) {
                        viewModel.showPremium = true
                    }
                    Button(L10n.restorePurchases) {
                        Task(priority: .userInitiated) {
                            try await AppStore.sync()
                        }
                    }
                }
                
                Section {
                    changePassword
                    reset
                }
                .navigationTitle(L10n.settings)
            
                Section {
                    Button(L10n.contact) {
                        guard let url = URL(string: "https://encrypted.camera/contact") else {
                            return
                        }
                        Task {
                            await UIApplication.shared.open(url)
                        }

                    }
                    Button(L10n.privacyPolicy) {
                        guard let url = URL(string: "https://encrypted.camera/privacy") else {
                            return
                        }
                        Task {
                            await UIApplication.shared.open(url)
                        }
                    }
                    Button(L10n.termsOfUse) {
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
        ProductStoreView()
    }
    
    private var reset: some View {
        NavigationLink(L10n.erase) {
            Form {
                Group {
                    NavigationLink {
                        PromptToErase(viewModel: .init(scope: .appData, keyManager: viewModel.keyManager, fileAccess: viewModel.fileAccess))
                        
                    } label: {
                        Text(L10n.eraseKeychainData)
                    }
                    NavigationLink {
                        PromptToErase(viewModel: .init(scope: .allData, keyManager: viewModel.keyManager, fileAccess: viewModel.fileAccess))
                        
                    } label: {
                        Text(L10n.eraseAllData)
                    }
                }.listRowBackground(Color.foregroundSecondary)
            }
            
            .foregroundColor(.red)
            .navigationTitle(L10n.erase)
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
        NavigationLink(L10n.changePassword, isActive: $viewModel.showDetailView) {
            Form {
                Group {
                    SecureField(L10n.currentPassword, text: $viewModel.currentPassword)
                    if let keyManagerError = viewModel.keyManagerError {
                        Text(keyManagerError.displayDescription).foregroundColor(.red)
                        
                    }
                    SecureField(L10n.newPassword, text: $viewModel.newPassword1)
                    
                    SecureField(L10n.repeatPassword, text: $viewModel.newPassword2)
                    if let validation = viewModel.passwordState {
                        Text(validation.validationDescription).foregroundColor(.red)
                    }
                    if let message = viewModel.successMessage {
                        Text(message).foregroundColor(.green)
                    }
                }.listRowBackground(Color.foregroundSecondary)
            }
            
            .scrollContentBackgroundColor(.background)
            .fontType(.small)
            .toolbar {
                Button(L10n.save) {
                    viewModel.savePassword()
                }
            }
            .navigationTitle(L10n.changePassword)
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
