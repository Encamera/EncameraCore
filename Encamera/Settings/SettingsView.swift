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
import WebKit

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
    @Published var useBiometrics: Bool = false
    var keyManager: KeyManager
    var fileAccess: FileAccess
    private var cancellables = Set<AnyCancellable>()
    private var passwordValidator = PasswordValidator()
    var authManager: AuthManager
    var availableBiometric: AuthenticationMethod? {
        return authManager.availableBiometric
    }
    
    init(keyManager: KeyManager, authManager: AuthManager, fileAccess: FileAccess) {
        self.keyManager = keyManager
        self.fileAccess = fileAccess
        self.authManager = authManager
        self.useBiometrics = authManager.useBiometricsForAuth
        
    }
    
    func setupBiometricToggleObserver() {
        self.$useBiometrics.sink { value in
            self.authManager.useBiometricsForAuth = value
        }.store(in: &cancellables)
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
        VStack(alignment: .leading, spacing: 0) {

            Text("Settings")
                .fontType(.large, on: .darkBackground, weight: .bold)
                .padding(.init(top: 0, leading: 24, bottom: 0, trailing: 24))
            List {
                Group {
                    Section {
                        Button(L10n.getPremium) {
                            viewModel.showPremium = true
                        }
                        Button(L10n.restorePurchases) {
                            Task(priority: .userInitiated) {
                                try await AppStore.sync()
                            }
                        }
                        Button(L10n.enterPromoCode) {
                            Task {
                                await StoreActor.shared.presentCodeRedemptionSheet()
                            }
                        }
                    }
                    Section {
                        Button(L10n.contact) {
                            let email = "mailto:alex+contact@freas.me"
                            let subject = "Encamera - Contact"
                            let urlString = "\(email)?subject=\(subject)"

                            guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
                                return
                            }

                            Task {
                                await UIApplication.shared.open(url)
                            }
                        }
                        Button(L10n.leaveAReview) {
                            AskForReviewUtil.requestReview()
                        }
                    }
                    Section {
                        changePassword
                        if viewModel.authManager.canAuthenticateWithBiometrics {
                            biometricsToggle
                        }
                    }
                    .navigationTitle(L10n.settings)

                    Section {
                        NavigationLink(L10n.openSource) {
                            WebView(url: URL(string: "https://encrypted.camera/open-source/")!)
                        }
                        NavigationLink(L10n.privacyPolicy) {
                            WebView(url: URL(string: "https://encrypted.camera/privacy/")!)
                        }
                        NavigationLink(L10n.roadmap) {
                            WebView(url: URL(string: "https://encamera.featurebase.app/")!)
                        }
                        NavigationLink(L10n.termsOfUse) {
                            WebView(url: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        }
                        reset
                    }

                }

            }
            .scrollContentBackgroundColor(.clear)

        }
        .gradientBackground()
        .fontType(.pt14, weight: .bold)
        .sheet(isPresented: $viewModel.showPremium) {
            premium
        }.padding(.bottom, 80)
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
                            .foregroundColor(.red)

                    }
                }
            }
            .gradientBackground()
            .foregroundColor(.red)
            .navigationTitle(L10n.erase)

            .scrollContentBackgroundColor(.background)
        }
        
        .sheet(isPresented: $viewModel.showPromptToErase) {
            promptToErase
        }
    }
    
    private var promptToErase: some View {
        return EmptyView()
    }
    
    private var biometricsToggle: some View {
        return Group {
            if let method = viewModel.availableBiometric {
                Toggle(isOn: $viewModel.useBiometrics) {
                    Text(L10n.use(method.nameForMethod))
                }.onAppear {
                    viewModel.setupBiometricToggleObserver()
                }.tint(Color.actionYellowGreen)
            } else {
                EmptyView()
            }
        }
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
                }
            }
            
            .scrollContentBackgroundColor(.background)
            .fontType(.pt18)
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

        SettingsView(viewModel: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), fileAccess: DemoFileEnumerator()))
        
    }
}
