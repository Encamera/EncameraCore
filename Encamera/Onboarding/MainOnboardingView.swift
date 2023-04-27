//
//  MainOnboardingView.swift
//  Encamera
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI
import LocalAuthentication
import EncameraCore

enum OnboardingViewError: Error {
    case passwordInvalid
    case onboardingEnded
    case missingStorageType
}

class OnboardingViewModel: ObservableObject {
    
    enum OnboardingKeyError: Error {
        case unhandledError
    }

    @Published var password1: String = ""
    @Published var showPassword = false
    @Published var password2: String = ""
    @Published var keyName: String = ""
    @Published var existingPassword: String = ""
    var onboardingFlow: [OnboardingFlowScreen]
    @Published var passwordState: PasswordValidation? 
    @MainActor
    @Published var stateError: OnboardingManagerError?
    @MainActor
    @Published var keySaveError: KeyManagerError?
    @MainActor
    @Published var generalError: Error?
    @MainActor
    @Published var keyStorageType: StorageType?
    @MainActor
    @Published var storageAvailabilities: [StorageAvailabilityModel] = []
    @Published var existingPasswordCorrect: Bool?
    @MainActor
    @Published var useBiometrics: Bool = false {
        didSet {
            guard useBiometrics == true else {
                return
            }
            Task {
                await authWithBiometrics()
            }
        }
    }
    @Published var saveToiCloud = false
    
    var availableBiometric: AuthenticationMethod? {
        return authManager.availableBiometric
    }
    
    
    private var onboardingManager: OnboardingManaging
    private var passwordValidator = PasswordValidator()
    var keyManager: KeyManager
    private var authManager: AuthManager
    
    
    
    init(onboardingManager: OnboardingManaging, keyManager: KeyManager, authManager: AuthManager) {
        self.onboardingManager = onboardingManager
        self.keyManager = keyManager
        self.authManager = authManager
        onboardingFlow = onboardingManager.generateOnboardingFlow()
        Task {
            await MainActor.run {
                self.keyStorageType = DataStorageUserDefaultsSetting().preselectedStorageSetting?.storageType
            }
        }
    }
    
    func validatePassword() -> PasswordValidation {
        let state = passwordValidator.validatePasswordPair(password1, password2: password2)
        self.passwordState = state
        return state
    }
    
    @MainActor
    func authWithBiometrics() async {
        do {
            try await authManager.evaluateWithBiometrics()
        } catch let authError as AuthManagerError {
            switch authError {
                
            case .passwordIncorrect:
                break
            case .biometricsFailed:
                
                    generalError = authError
                
            case .biometricsNotAvailable, .userCancelledBiometrics:
                
                useBiometrics = false
            }
        } catch {
            generalError = error
        }
    }
    
    @MainActor
    func validateKeyName() throws {
        do {
            try keyManager.validateKeyName(name: keyName)
            
        } catch {
            try handle(error: error)
        }
    }
    
    @MainActor
    func validateStorageSelection() throws {
        
        if keyStorageType == nil {
            try handle(error: OnboardingViewError.missingStorageType)
        }
    }
    
    @MainActor
    func handle(error: Error) throws {
        switch error {
        case let managerError as OnboardingManagerError:
            stateError = managerError
        case let keyError as KeyManagerError:
            keySaveError = keyError
        default:
            generalError = error
        }
        throw error
    }
    
    @MainActor func savePassword() throws {
        do {
            let validation = validatePassword()
            if validation == .valid {
                try keyManager.setPassword(password1)
            } else {
                throw OnboardingViewError.passwordInvalid
            }
        } catch {
            try handle(error: error)
        }
    }
    
    @MainActor
    func checkExistingPasswordAndAuth() {
        do {
            existingPasswordCorrect = try keyManager.checkPassword(existingPassword)
            if existingPasswordCorrect == false {
                generalError = OnboardingViewError.passwordInvalid
            }
        } catch {
            generalError = OnboardingViewError.passwordInvalid
        }
    }
    
    func saveState() async throws {
        
        do {
            let savedState = OnboardingState.completed
            if existingPassword.isEmpty == false {
                try authManager.authorize(with: existingPassword, using: keyManager)
            } else if let storageType = await keyStorageType {
                try authManager.authorize(with: password1, using: keyManager)
                try keyManager.generateNewKey(name: AppConstants.defaultKeyName, storageType: storageType, backupToiCloud: saveToiCloud)
            }
            try await onboardingManager.saveOnboardingState(savedState, settings: SavedSettings(useBiometricsForAuth: await useBiometrics))
            
        } catch {
            try await handle(error: error)
        }
    }
}

struct MainOnboardingView: View {
    
    
    @FocusState var password2Focused
    @State var currentSelection = OnboardingFlowScreen.intro
    @StateObject var viewModel: OnboardingViewModel
    
    var body: some View {
        NavigationView {
            buildOnboarding()
                .background(Color.background)
            }
        .ignoresSafeArea(.keyboard)
    }

    private func canGoTo(tab: OnboardingFlowScreen) -> Bool {
        if let currentIndex = viewModel.onboardingFlow.firstIndex(of: currentSelection),
           let targetIndex = viewModel.onboardingFlow.firstIndex(of: tab),
           targetIndex < currentIndex {
            return true
        }
        return false
    }
    
}

private extension MainOnboardingView {
    
    func viewFor<Next: View>(flow: OnboardingFlowScreen, next: @escaping () -> Next) -> AnyView {
        let index = (viewModel.onboardingFlow.firstIndex(of: flow) ?? 0) + 1
        
        var model = viewModel(for: flow)
        model.progress = (index, viewModel.onboardingFlow.count)
        return AnyView(OnboardingView(
            viewModel: model, nextScreen: {
                next()
            })
        )
    }
    
    func buildOnboarding() -> some View {
        
        let lastView: AnyView? = nil
        
        let views = viewModel.onboardingFlow.reversed().reduce(lastView) { partialResult, screen in
            return viewFor(flow: screen, next: {
                partialResult
            })
        }
        return views
    }
    
    func viewModel(for flow: OnboardingFlowScreen) -> OnboardingViewViewModel {
        
        switch flow {
        case .intro:
            return .init(
                title: "",
                subheading: "",
                image: Image(systemName: "camera"),
                bottomButtonTitle: L10n.next,
                bottomButtonAction: {
                    
                }) {
                    AnyView(VStack(alignment: .leading, spacing: 10) {
                        Image("EncameraBanner")
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text(L10n.readyToTakeBackYourMedia📸)
                            .fontType(.medium, weight: .bold)
                        Text(L10n.encameraEncryptsAllDataItCreatesKeepingYourDataSafeFromThePryingEyesOfAIMediaAnalysisAndOtherViolationsOfPrivacy)
                            .fontType(.small)
                        Text(L10n.keyBasedEncryption🔑)
                            .fontType(.medium, weight: .bold)
                        Text(L10n.yourMediaIsSafelySecuredBehindAKeyAndStoredLocallyOnYourDeviceOrCloudOfChoice)
                        Text(L10n.forYourEyesOnly👀)
                            .fontType(.medium, weight: .bold)
                        Text(L10n.NoTrackingNoFunnyBusiness.takeControlOfWhatSRightfullyYoursYourMediaYourDataYourPrivacy)
                            .fontType(.small)
                        Spacer()
                    })
                    
                }
            
        case .enterExistingPassword:
            return .init(
                title: L10n.enterPassword,
                subheading: L10n.youHaveAnExistingPasswordForThisDevice, image: Image(systemName: "key.fill"), bottomButtonTitle: L10n.next, bottomButtonAction: {
                    viewModel.checkExistingPasswordAndAuth()
                }) {
                    AnyView(
                        VStack(alignment: .leading) {
                            PasswordEntry(viewModel: .init(keyManager: viewModel.keyManager, passwordBinding: $viewModel.existingPassword, stateUpdate: { state in
                                guard case .valid(let existingPassword) = state else {
                                    return
                                }
                                viewModel.existingPassword = existingPassword
                                viewModel.checkExistingPasswordAndAuth()
                            }))
                            if let error = viewModel.generalError as? OnboardingViewError, case .passwordInvalid = error {
                                Group {
                                    Text(error.localizedDescription).alertText()
                                }
                            }

                            NavigationLink {
                                PromptToErase(viewModel: .init(scope: .appData, keyManager: viewModel.keyManager, fileAccess: DiskFileAccess()))
                            } label: {
                                Text(L10n.eraseDeviceData)
                            }.primaryButton()
                        }
                    )
                }
        case .setPassword:
            return .init(
                title: L10n.setPassword,
                subheading: L10n.SetAPasswordToAccessTheApp.BeSureToStoreItInASafePlaceYouCannotRecoverItLater.🙅,
                image: Image(systemName: "lock.iphone"),
                bottomButtonTitle: L10n.setPassword,
                bottomButtonAction: {
                    try viewModel.savePassword()
                }) {
                    AnyView(
                        VStack(alignment: .leading) {
                                VStack {
                                    Group {
                                        EncameraTextField(L10n.password, type: viewModel.showPassword ? .normal : .secure, text: $viewModel.password1).onSubmit {
                                            password2Focused = true
                                        }
                                        EncameraTextField(L10n.repeatPassword, type: viewModel.showPassword ? .normal : .secure, text: $viewModel.password2)
                                            .focused($password2Focused)
                                            .onSubmit {
                                                password2Focused = false
                                            }
                                    }.noAutoModification()
                                    HStack {
                                        Button {
                                            viewModel.showPassword.toggle()
                                        } label: {
                                            Image(systemName: viewModel.showPassword ? "eye" : "eye.slash")
                                        }.padding()
                                        Spacer()
                                    }
                                
                            }
                            if let passwordState = viewModel.passwordState, passwordState != .valid {
                                Group {
                                    Text(passwordState.validationDescription).alertText()
                                }
                            }
                        })
                    
                }
        case .biometrics:
            guard let method = viewModel.availableBiometric else {
                return viewModel(for: .finished)
            }
            return .init(
                title: L10n.use(method.nameForMethod),
                subheading: L10n.enableToQuicklyAndSecurelyGainAccessToTheApp(method.nameForMethod),
                image: Image(systemName: method.imageNameForMethod),
                bottomButtonTitle: L10n.next, content:  {
                    AnyView(Group {HStack {
                        Toggle(L10n.enable(method.nameForMethod), isOn: $viewModel.useBiometrics)
                            .fontType(.small)
                    }})
                })
        case .setupPrivateKey:
            return .init(
                title: L10n.encryptionKey,
                subheading:
                    L10n.newKeySubheading,
                image: Image(systemName: "key.fill"),
                bottomButtonTitle: L10n.next,
                bottomButtonAction: {
                    try viewModel.validateKeyName()
                }) {
                    AnyView(
                        VStack {
                            EncameraTextField(L10n.keyName, text: $viewModel.keyName)
                                .noAutoModification()
                                
                            if let keySaveError = viewModel.keySaveError {
                                Text(keySaveError.displayDescription)
                                    .alertText()
                            }
                        }
                    )
                }
        case .dataStorageSetting:


            return .init(title: L10n.selectStorage,
                         subheading: L10n.storageLocationOnboarding,
                         image: Image(systemName: ""),
                         bottomButtonTitle: L10n.next) {
                try viewModel.validateStorageSelection()
            } content: {
                AnyView(
                    VStack {
                        StorageSettingView(viewModel: .init(), keyStorageType: $viewModel.keyStorageType)
                        if case .missingStorageType = viewModel.generalError as? OnboardingViewError {
                            Text(L10n.pleaseSelectAStorageLocation)
                                .alertText()
                        }
                        Group {
                            Toggle(L10n.saveKeyToICloud, isOn: $viewModel.saveToiCloud)
                            Text(L10n.ifYouDonTUseICloudBackupItSHighlyRecommendedThatYouBackupYourKeysToAPasswordManagerOrSomewhereElseSafe)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fontType(.small)

                    }
                )
                
            }

        case .finished:
            return .init(
                title: L10n.doneOnboarding,
                subheading: L10n.allSetupOnboarding,
                image: Image(systemName: "faceid"),
                bottomButtonTitle: L10n.done,
                bottomButtonAction: {
                    try await viewModel.saveState()
                    throw OnboardingViewError.onboardingEnded
                })
        }
    }
    
    @ViewBuilder func storageButton(imageName: String, text: String, isSelected: Binding<Bool>, action: @escaping () -> Void) -> some View {
        let background = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let output = Button(action: {
            isSelected.wrappedValue = true
            action()
        }, label: {
            
            VStack {
                Image(systemName: imageName).resizable()
                    .aspectRatio(contentMode: .fit)
                
                Text(text)
                    .fontType(.small)
            }.padding()
        })
        .frame(width: 100, height: 100)
        
        if isSelected.wrappedValue == true {
            output
                .foregroundColor(Color.background)
                .background(background.fill(Color.foregroundPrimary))

        } else {
            output
                .overlay(background.stroke(Color.foregroundSecondary, lineWidth: 3))

        }
    }

}

struct MainOnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        MainOnboardingView(viewModel: .init(onboardingManager: DemoOnboardingManager(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), settingsManager: SettingsManager()), keyManager: DemoKeyManager(), authManager: DemoAuthManager()))
            .preferredColorScheme(.dark)
            .previewDevice("iPhone 8")
            .background(Color.background)
    }
}


