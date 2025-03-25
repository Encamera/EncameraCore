//
//  SettingsView.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import SwiftUI
import Combine
import EncameraCore
import WebKit
import RevenueCat

fileprivate enum AlertType {
    case none
    case pinRemembered
    case biometricsDisabledOpenSettings
    case purchasesRestored
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
    @Published var showPurchaseScreen: Bool = false
    @Published fileprivate var successMessage: String?
    @Published var useBiometrics: Bool = false
    @Published var activeChangePasscodeModal: PasscodeType?
    @Published var pinRememberedConfirmed: Bool = false
    @Published fileprivate var activeAlert: AlertType = .none
    @Published var showKeyBackup: Bool = false
    @Published var useiCloudKeyBackup: Bool = false
    @Published var defaultStorageOption: StorageType = .local {
        didSet {
            albumManager.defaultStorageForAlbum = defaultStorageOption
        }
    }

    var keyManager: KeyManager
    var fileAccess: FileAccess
    var albumManager: AlbumManaging
    var purchasedPermissions: PurchasedPermissionManaging

    private var cancellables = Set<AnyCancellable>()
    private var passwordValidator = PasswordValidator()
    var authManager: AuthManager
    var availableBiometric: AuthenticationMethod? {
        return authManager.availableBiometric
    }

    var isUsingPinCode: Bool {
        if case .pinCode = keyManager.passcodeType {
            return true
        }
        return false
    }
    
    var isUsingPassword: Bool {
        if case .password = keyManager.passcodeType {
            return true
        }
        return false
    }
    
    @MainActor
    init(keyManager: KeyManager,
         authManager: AuthManager,
         fileAccess: FileAccess,
         albumManager: AlbumManaging,
         purchasedPermissions: PurchasedPermissionManaging) {
        self.keyManager = keyManager
        self.albumManager = albumManager
        self.fileAccess = fileAccess
        self.authManager = authManager
        self.useBiometrics = authManager.useBiometricsForAuth
        self.showKeyBackup = ((try? keyManager.retrieveKeyPassphrase()) != nil)
        self.defaultStorageOption = albumManager.defaultStorageForAlbum
        self.purchasedPermissions = purchasedPermissions
        self.useiCloudKeyBackup = purchasedPermissions.hasEntitlement && keyManager.areKeysStoredIniCloud
    }
    
    func setupToggleObservers() {
        self.$useBiometrics.dropFirst().sink { [weak self] value in
            if self?.authManager.canAuthenticateWithBiometrics == false {
                self?.activeAlert = .biometricsDisabledOpenSettings
                return
            }
            if value == true {
                self?.toggleBiometrics(value: true)
                return
            }
            guard self?.keyManager.passwordExists() ?? false else {
                self?.activeChangePasscodeModal = .pinCode(length: .four)
                return
            }

            guard self?.pinRememberedConfirmed ?? false else {
                self?.activeAlert = .pinRemembered
                return
            }
        }.store(in: &cancellables)

        self.$useiCloudKeyBackup.dropFirst().sink { [weak self] value in
            guard let self else { return }
            if self.purchasedPermissions.hasEntitlement {
                try? self.keyManager.backupKeychainToiCloud(backupEnabled: value)
            } else {
                self.showPurchaseScreen = value
                self.useiCloudKeyBackup = false
            }
        }.store(in: &cancellables)
    }

    func toggleBiometrics(value: Bool) {


        authManager.useBiometricsForAuth = value
        if value == true {
            Task { @MainActor in
                EventTracking.trackBiometricsEnabled()
            }
            Task { [weak self] in
                try await self?.authManager.authorizeWithBiometrics()
            }
        } else {
            Task { @MainActor in
                EventTracking.trackBiometricsDisabled()
            }
        }
    }

    func resetPasswordInputs() {
        keyManagerError = nil
        passwordState = nil
        newPassword1 = ""
        newPassword2 = ""
        currentPassword = ""
    }

    func eraseKeychainData() {
        
    }
    
    func eraseAllData() {
        
    }
    
}

struct SettingsView: View {
    
    
    @EnvironmentObject var appModalStateModel: AppModalStateModel

    @StateObject var viewModel: SettingsViewViewModel
    
    init(viewModel: SettingsViewViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewHeader(title: L10n.settings)
            List {
                Group {
                    Section {
                        Button(L10n.getPremium) {
                            viewModel.showPurchaseScreen = true
                        }
                        Button(L10n.restorePurchases) {
                            Task(priority: .userInitiated) {
                                let _ = try await Purchases.shared.restorePurchases()
                                await viewModel.purchasedPermissions.refreshEntitlements()
                                Task { @MainActor in
                                    self.viewModel.activeAlert = .purchasesRestored
                                }
                            }
                        }
                        Button(L10n.enterPromoCode) {
                            Purchases.shared.presentCodeRedemptionSheet()
                        }
                    }
                    Section {
                        Button(L10n.joinTelegramGroup) {
                            Task {
                                EventTracking.trackSettingsTelegramPressed()
                                await UIApplication.shared.open(URL(string: "https://t.me/encamera_app")!)
                            }
                        }
                        Button(L10n.Settings.contact) {
                            EventTracking.trackSettingsContactPressed()
                            let email = "mailto:alex@encamera.app"
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
                        Button(L10n.Settings.giveInstantFeedback) {
                            appModalStateModel.currentModal = .feedbackView
                        }
                        NavigationLink(L10n.roadmap, value: AppNavigationPaths.roadmap)

                    }
                    Section {
                        if viewModel.keyManager.passwordExists() {
                            Button {
                                viewModel.activeChangePasscodeModal = viewModel.keyManager.passcodeType
                            } label: {
                                Text(L10n.changePasscode)
                            }
                        }
                        biometricsToggle
                        NavigationLink(L10n.authenticationMethod, value: AppNavigationPaths.authenticationMethod)
                        if viewModel.showKeyBackup {
                            NavigationLink(L10n.Settings.backupKeyPhrase, value: AppNavigationPaths.backupKeyPhrase)
                            NavigationLink(L10n.Settings.importKeyPhrase, value: AppNavigationPaths.importKeyPhrase)
                        }
                        HStack {
                            Picker(L10n.Settings.defaultStorageOption, selection: $viewModel.defaultStorageOption) {
                                ForEach(StorageType.allCases) { storageType in
                                    Text(storageType.title)
                                }
                            }
                            .fontType(.pt14, weight: .bold)
                        }
                    }
                    .navigationTitle(L10n.settings)

                    Section {
                        NavigationLink(L10n.openSource, value: AppNavigationPaths.openSource)
                        NavigationLink(L10n.privacyPolicy, value: AppNavigationPaths.privacyPolicy)
                        NavigationLink(L10n.termsOfUse, value: AppNavigationPaths.termsOfUse)
                        reset

                    }
                    Section {
                        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown version"
                        Text("\(L10n.Settings.version) \(appVersion)")
                    }
                }
                .padding(.init(top: 10, leading: 0, bottom: 10, trailing: 0))
            }
            .scrollIndicators(.hidden)
            .scrollContentBackgroundColor(.clear)

        }
        .gradientBackground()
        .fontType(.pt14, weight: .bold)
        .productStorefront(isPresented: $viewModel.showPurchaseScreen, fromViewName: "Settings")
        .sheet(isPresented: Binding<Bool>(get: {
            return viewModel.activeChangePasscodeModal != nil
        }, set: { value in
            if value == false {
                viewModel.activeChangePasscodeModal = nil
            }
        })) {
            if let passcodeType = viewModel.activeChangePasscodeModal {
                if case .pinCode(let length) = passcodeType {
                    ChangePinModal(viewModel: .init(keyManager: viewModel.keyManager, pinLength: length, completedAction: {
                        // tiny hack but we are relying here on the UI to keep the state of the biometrics
                        viewModel.toggleBiometrics(value: viewModel.useBiometrics)
                    }))
                } else {
                    PasswordEntry(viewModel: .init(
                        keyManager: viewModel.keyManager,
                        stateUpdate: { _ in },
                        completedAction: {
                            // Same biometrics handling as with PIN
                            viewModel.toggleBiometrics(value: viewModel.useBiometrics)
                        }
                    ))
                }
            }
        }
        .alert(isPresented: Binding<Bool>(get: {
            return viewModel.activeAlert != .none
        }, set: { value in
            if value == false {
                viewModel.activeAlert = .none
            }
        })) {

            switch viewModel.activeAlert {
            case .pinRemembered:
                Alert(title: Text(L10n.doYouRememberYourPin), message: Text(L10n.doYouRememberYourPinSubtitle), primaryButton: .default(Text(L10n.iRemember)) {
                    viewModel.toggleBiometrics(value: viewModel.useBiometrics)
                }, secondaryButton: .default(Text(L10n.iForgot)) {
                    viewModel.activeChangePasscodeModal = viewModel.keyManager.passcodeType
                })
            case .biometricsDisabledOpenSettings:
                Alert(title: Text(L10n.settingsFaceIdDisabled), message: Text(L10n.settingsFaceIdOpenSettings), primaryButton: .default(Text(L10n.openSettings), action: {
                    if let url = URL(string: UIApplication.openSettingsURLString), UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    }
                }), secondaryButton: .cancel({
                    viewModel.useBiometrics = false
                }))
            case .purchasesRestored:
                Alert(title: Text(L10n.Settings.purchasesRestored), message: Text(L10n.Settings.purchasesRestoredMessage), dismissButton: .default(Text(L10n.ok)))
            case .none:
                Alert(title: Text("Error"), message: Text("Unknown error"), dismissButton: .default(Text(L10n.ok)))
            }
        }
        .padding(.bottom, 90)
    }
    
    private var reset: some View {
        Group {
            NavigationLink(L10n.eraseAllData, value: AppNavigationPaths.eraseAllData)
            NavigationLink(L10n.eraseAppData, value: AppNavigationPaths.eraseAppData)
        }
    }
    
    private var promptToErase: some View {
        return EmptyView()
    }
    
    private var biometricsToggle: some View {
        return Group {
            let method = viewModel.authManager.deviceBiometryType ?? .faceID
            Toggle(isOn: $viewModel.useBiometrics) {
                Text(L10n.use(method.nameForMethod))
            }.onAppear {
                viewModel.setupToggleObservers()
            }.tint(Color.actionYellowGreen)

        }
    }

    private var iCloudKeyBackupToggle: some View {
        return Group {
            Toggle(isOn: $viewModel.useiCloudKeyBackup) {
                Text(L10n.Settings.backupKeyToiCloud)
            }.tint(Color.actionYellowGreen)
        }
    }


}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {

        SettingsView(viewModel: .init(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), fileAccess: DemoFileEnumerator(), albumManager: DemoAlbumManager(), purchasedPermissions: DemoPurchasedPermissionManaging()))

    }
}
