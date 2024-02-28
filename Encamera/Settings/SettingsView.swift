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
    @Published var showChangePin: Bool = false
    @Published var pinRememberedConfirmed: Bool = false
    @Published var showPinRememberedAlert: Bool = false

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
        self.$useBiometrics.dropFirst().sink { [weak self] value in
            if value == true {
                self?.toggleBiometrics(value: true)
                return
            }
            guard self?.keyManager.passwordExists() ?? false else {
                self?.showChangePin = true
                return
            }

            guard self?.pinRememberedConfirmed ?? false else {
                self?.showPinRememberedAlert = true
                return
            }
        }.store(in: &cancellables)
    }

    func toggleBiometrics(value: Bool) {


        authManager.useBiometricsForAuth = value
        if value == true {
            EventTracking.trackBiometricsEnabled()
            Task { [weak self] in
                try await self?.authManager.authorizeWithBiometrics()
            }
        } else {
            EventTracking.trackBiometricsDisabled()
        }
    }

    func resetPasswordInputs() {
        keyManagerError = nil
        passwordState = nil
        newPassword1 = ""
        newPassword2 = ""
        currentPassword = ""
    }
//    func savePassword() {
//        do {
//            self.keyManagerError = nil
//            self.passwordState = nil
//            let _ = try keyManager.checkPassword(currentPassword)
//            let passwordState =  PasswordValidator.validatePasswordPair(newPassword1, password2: newPassword2)
//            guard case .valid = passwordState else {
//                self.passwordState = passwordState
//                return
//            }
//            try keyManager.changePassword(newPassword: newPassword1, existingPassword: currentPassword)
//            Just(false).delay(for: .seconds(1), scheduler: RunLoop.main)
//                .sink { _ in
//                    self.showDetailView = false
//                    self.successMessage = nil
//                }.store(in: &cancellables)
//            self.successMessage = L10n.passwordSuccessfullyChanged
//            resetPasswordInputs()
//        } catch let keyManagerError as KeyManagerError {
//            self.keyManagerError = keyManagerError
//        } catch {
//            print("Change password failed: ", error)
//        }
//    }
    
    func eraseKeychainData() {
        
    }
    
    func eraseAllData() {
        
    }
    
}

struct SettingsView: View {
    
    
    @Environment(\.presentationMode) private var presentationMode

    func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }


    @StateObject var viewModel: SettingsViewViewModel
    
    init(viewModel: SettingsViewViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            Text(L10n.settings)
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
                        Button(L10n.joinTelegramGroup) {
                            Task {
                                EventTracking.trackSettingsTelegramPressed()
                                await UIApplication.shared.open(URL(string: "https://t.me/encamera_app")!)
                            }
                        }
                        Button(L10n.contact) {
                            EventTracking.trackSettingsContactPressed()
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
                            EventTracking.trackSettingsLeaveReviewPressed()
                            AskForReviewUtil.openAppStoreReview()
                        }
                    }
                    Section {
                        let _ = Self._printChanges()

                        Button {
                            viewModel.showChangePin = true
                        } label: {
                            Text(L10n.changePassword)
                        }

                        if viewModel.authManager.canAuthenticateWithBiometrics {
                            biometricsToggle
                        }
//                        NavigationLink("Key Phrase") {
//                            KeyPhraseView(viewModel: .init(keyManager: viewModel.keyManager))
//                        }
//                        NavigationLink("Import Key Phrase") {
//                            ImportKeyPhrase(viewModel: .init(keyManager: viewModel.keyManager))
//                        }
                    }
                    .navigationTitle(L10n.settings)

                    Section {
                        NavigationLink(L10n.openSource) {
                            WebView(url: URL(string: "https://encamera.app/open-source/")!)
                        }.id(UUID())
                        NavigationLink(L10n.privacyPolicy) {
                            WebView(url: URL(string: "https://encamera.app/privacy/")!)
                        }.id(UUID())
                        NavigationLink(L10n.roadmap) {
                            WebView(url: URL(string: "https://encamera.featurebase.app/")!)
                        }.id(UUID())
                        NavigationLink(L10n.termsOfUse) {
                            WebView(url: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        }.id(UUID())
                        reset
                    }

                }
                .padding(.init(top: 10, leading: 0, bottom: 10, trailing: 0))
            }
            .scrollIndicators(.hidden)
            .scrollContentBackgroundColor(.clear)

        }
        .gradientBackground()
        .fontType(.pt14, weight: .bold)
        .productStore(isPresented: $viewModel.showPremium, fromViewName: "Settings")
        .sheet(isPresented: $viewModel.showChangePin, content: {
            ChangePinModal(viewModel: .init(authManager: viewModel.authManager, keyManager: viewModel.keyManager, completedAction: {
                // tiny hack but we are relying here on the UI to keep the state of the biometrics
                viewModel.toggleBiometrics(value: viewModel.useBiometrics)
            }))
        })
        .alert(isPresented: $viewModel.showPinRememberedAlert) {
            Alert(title: Text(L10n.doYouRememberYourPin), message: Text(L10n.doYouRememberYourPinSubtitle), primaryButton: .default(Text(L10n.iRemember)) {
                viewModel.toggleBiometrics(value: viewModel.useBiometrics)
            }, secondaryButton: .default(Text(L10n.iForgot)) {
                viewModel.showChangePin = true
            })
        }
        .padding(.bottom, 90)
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
    

}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {

        SettingsView(viewModel: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), fileAccess: DemoFileEnumerator()))
        
    }
}
