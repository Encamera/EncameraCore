//
//  MainOnboardingView.swift
//  Encamera
//
//  Created by Alexander Freas on 13.07.22.
//

import Combine
import EncameraCore
import LocalAuthentication
import SwiftUI

enum OnboardingViewError: Error {
    case passwordInvalid
    case onboardingEnded
    case missingStorageType
    case advanceImageCarousel // hax
}

class OnboardingViewModel<GenericAlbumManaging: AlbumManaging>: ObservableObject {
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
    @MainActor
    @Published var existingPasswordCorrect: Bool?
    @MainActor
    @Published var isShowingAlertForPermissions: Bool = false
    @MainActor
    @Published var useBiometrics: Bool = false
    @Published var saveToiCloud = false
    @Published var currentOnboardingImageIndex = 0

    var availableBiometric: AuthenticationMethod? {
        return authManager.availableBiometric
    }

    private var cancellables = Set<AnyCancellable>()

    private var onboardingManager: OnboardingManaging
    private var albumManager: GenericAlbumManaging?
    var keyManager: KeyManager
    private var authManager: AuthManager

    private var lastPasswordLength = 0

    init(onboardingManager: OnboardingManaging, keyManager: KeyManager, authManager: AuthManager) {
        self.onboardingManager = onboardingManager
        self.keyManager = keyManager
        self.authManager = authManager
        onboardingFlow = onboardingManager.generateOnboardingFlow()
        Task {
            await MainActor.run {
                self.keyStorageType = albumManager?.defaultStorageForAlbum
            }
        }
        $password1.sink { password in
            let newLength = password.lengthOfBytes(using: .utf8)
            if password != self.password1 && newLength - self.lastPasswordLength > 2 {
                self.password2 = password
            }
            self.lastPasswordLength = newLength
        }.store(in: &cancellables)
    }

    @discardableResult func validatePassword() throws -> PasswordValidation {
        let state = PasswordValidator.validatePasswordPair(password1, password2: password2)
        passwordState = state

        if state != .valid {
            throw OnboardingViewError.passwordInvalid
        }
        return state
    }

    @MainActor
    func authWithBiometrics() async throws {
        do {
            try await authManager.evaluateWithBiometrics()
            useBiometrics = true
        } catch let authError as AuthManagerError {
            switch authError {
            case .passwordIncorrect:
                break
            case .biometricsFailed:

                generalError = authError

            case .biometricsNotAvailable, .userCancelledBiometrics:

                useBiometrics = false
            }
            throw authError
        } catch {
            generalError = error
            throw error
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
            let validation = try validatePassword()
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
    func checkExistingPasswordAndAuth() throws {
        do {
            existingPasswordCorrect = try keyManager.checkPassword(existingPassword)
            if existingPasswordCorrect == false {
                generalError = OnboardingViewError.passwordInvalid
                throw OnboardingViewError.passwordInvalid
            }
        } catch {
            generalError = OnboardingViewError.passwordInvalid
            throw OnboardingViewError.passwordInvalid
        }
    }

    func saveState() async throws {
        do {
            let savedState = OnboardingState.completed

            if existingPassword.isEmpty == false {
                try authManager.authorize(with: existingPassword, using: keyManager)
            } else {
                try await savePassword()
                try authManager.authorize(with: password1, using: keyManager)
            }
            let keys = try? keyManager.storedKeys()
            if keys == nil || keys?.isEmpty ?? false {
                let _ = try keyManager.generateKeyUsingRandomWords(name: AppConstants.defaultKeyName)
            }

            var albumManager = GenericAlbumManaging(keyManager: keyManager)
            let album = try? albumManager.create(name: AppConstants.defaultAlbumName, storageOption: .local)
            albumManager.currentAlbum = album
            self.albumManager = albumManager
            UserDefaultUtils.set(true, forKey: .showCameraOnLaunch)

            try await onboardingManager.saveOnboardingState(savedState, settings: SavedSettings(useBiometricsForAuth: await useBiometrics))

        } catch {
            try await handle(error: error)
        }
    }
}

struct MainOnboardingView<GenericAlbumManaging: AlbumManaging>: View {
    @FocusState var password2Focused
    @State var currentSelection = OnboardingFlowScreen.intro
    @StateObject var viewModel: OnboardingViewModel<GenericAlbumManaging>
    @ObservedObject var cameraPermissions = CameraPermissionsService.shared
    var body: some View {
        NavigationView {
            buildOnboarding()
                .background(Color.background)
        }
        .ignoresSafeArea(.keyboard)
        .alert(
            L10n.permissionsNeededTitle,
            isPresented: $viewModel.isShowingAlertForPermissions,
            presenting: L10n.permissionsNeededText)
        { _ in
            Button(L10n.openSettings) {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }
            Button(L10n.cancel) {
                viewModel.isShowingAlertForPermissions = false
            }
        } message: { details in
            Text(details)
        }
    }

    private func canGoTo(tab: OnboardingFlowScreen) -> Bool {
        if let currentIndex = viewModel.onboardingFlow.firstIndex(of: currentSelection),
           let targetIndex = viewModel.onboardingFlow.firstIndex(of: tab),
           targetIndex < currentIndex
        {
            return true
        }
        return false
    }
}

private extension MainOnboardingView {
    func viewFor<Next: View>(flow: OnboardingFlowScreen, next: @escaping () -> Next) -> AnyView {
        let index = (viewModel.onboardingFlow.firstIndex(of: flow) ?? 0)

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
            viewFor(flow: screen, next: {
                partialResult
            })
        }
        return views
    }

    func viewModel(for flow: OnboardingFlowScreen) -> OnboardingViewViewModel {
        switch flow {
        case .intro:
            return .init(
                screen: flow,
                showTopBar: false,
                bottomButtonTitle: viewModel.currentOnboardingImageIndex < 2 ? L10n.next : L10n.getStartedButtonText,
                bottomButtonAction: {
                    if viewModel.currentOnboardingImageIndex < 2 {
                        viewModel.currentOnboardingImageIndex += 1
                        throw OnboardingViewError.advanceImageCarousel
                    }
                }) { _ in

                    AnyView(
                        VStack {
                            OnboardingImageCarousel(currentScrolledToImage: $viewModel.currentOnboardingImageIndex)
                            Spacer()
                        }.padding(0)
                    )
                }

        case .enterExistingPassword:
            let model = PasswordEntryViewModel(keyManager: viewModel.keyManager, passwordBinding: $viewModel.existingPassword, stateUpdate: { state in
                guard case .valid(let existingPassword) = state else {
                    return
                }
                viewModel.existingPassword = existingPassword
                try? viewModel.checkExistingPasswordAndAuth()
            })

            return .init(
                screen: flow,
                title: L10n.enterPassword,
                subheading: L10n.youHaveAnExistingPasswordForThisDevice, image: Image(systemName: "key.fill"), bottomButtonTitle: L10n.next, bottomButtonAction: {
                    try viewModel.checkExistingPasswordAndAuth()
                }) { _ in
                    AnyView(
                        VStack(alignment: .leading) {
                            PasswordEntry(viewModel: model)
                            if let error = viewModel.generalError as? OnboardingViewError, error == OnboardingViewError.passwordInvalid {
                                Text(L10n.invalidPassword).alertText()
                            }

                            NavigationLink {
                                PromptToErase(viewModel: .init(scope: .appData, keyManager: viewModel.keyManager, fileAccess: InteractableMediaDiskAccess()))
                            } label: {
                                Text(L10n.eraseDeviceData)
                            }.primaryButton()
                        }
                    )
                }
        case .setPassword:
            return .init(
                screen: flow,
                title: L10n.setPassword,
                subheading: L10n.setAPasswordWarning,
                image: Image("Onboarding-Password"),
                bottomButtonTitle: L10n.setPassword,
                bottomButtonAction: {
                    try viewModel.validatePassword()
                })
            { _ in
                AnyView(
                    VStack(alignment: .leading) {
                        VStack {
                            Group {
                                EncameraTextField(L10n.password,
                                                  type: viewModel.showPassword ? .normal : .secure,
                                                  contentType: .newPassword,
                                                  text: $viewModel.password1,
                                                  becomeFirstResponder: true,
                                                  accessibilityIdentifier: "password").onSubmit {
                                    password2Focused = true
                                }

                                EncameraTextField(L10n.repeatPassword,
                                                  type: viewModel.showPassword ? .normal : .secure,
                                                  contentType: .newPassword, text: $viewModel.password2,
                                                  accessibilityIdentifier: "passwordConfirmation")
                                .focused($password2Focused)
                                .onSubmit {
                                    password2Focused = false
                                }
                            }
                            .noAutoModification()
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
                screen: flow,
                title: L10n.enable(method.nameForMethod),
                subheading: L10n.enableToQuicklyAndSecurelyGainAccessToTheApp(method.nameForMethod),
                image: Image(systemName: method.imageNameForMethod),
                bottomButtonTitle: L10n.enable(method.nameForMethod),
                bottomButtonAction: {
                    try await viewModel.authWithBiometrics()
                    EventTracking.trackOnboardingBiometricsEnabled()
                }, content: { goToNext in
                    AnyView(
                        Text(L10n.skipForNow)
                            .fontType(.pt14, on: .textButton, weight: .bold)
                            .onTapGesture {
                                EventTracking.trackOnboardingBiometricsSkipped()
                                goToNext()
                            }
                    )
                })
        case .setupPrivateKey:
            return .init(
                screen: flow,
                title: L10n.encryptionKey,
                subheading:
                L10n.newAlbumSubheading,
                image: Image(systemName: "key.fill"),
                bottomButtonTitle: L10n.next,
                bottomButtonAction: {
                    try viewModel.validateKeyName()
                }) { _ in
                    AnyView(
                        VStack {
                            EncameraTextField(L10n.albumName, text: $viewModel.keyName)
                                .noAutoModification()
                            if let keySaveError = viewModel.keySaveError {
                                Text(keySaveError.displayDescription)
                                    .alertText()
                            }
                        }
                    )
                }
        case .dataStorageSetting:

            return .init(
                screen: flow,
                title: L10n.selectStorage,
                subheading: L10n.storageLocationOnboarding,
                image: Image("Onboarding-Storage"),
                bottomButtonTitle: L10n.next)
            {
                try viewModel.validateStorageSelection()
            } content: { _ in
                AnyView(
                    VStack {
                        StorageSettingView(viewModel: .init(), keyStorageType: $viewModel.keyStorageType)
                        if case .missingStorageType = viewModel.generalError as? OnboardingViewError {
                            Text(L10n.pleaseSelectAStorageLocation)
                                .alertText()
                        }

                    }.padding(10)
                )
            }
        case .permissions:
            return .init(
                screen: flow,
                title: L10n.onboardingPermissionsTitle,
                subheading: L10n.onboardingPermissionsSubheading,
                image: Image("Onboarding-Permissions"),
                bottomButtonTitle: cameraPermissions.isCameraAccessAuthorized && cameraPermissions.isMicrophoneAccessAuthorized ? L10n.done : L10n.addPermissions, bottomButtonAction: {
                    do {
                        try await self.cameraPermissions.requestCameraPermission()
                        EventTracking.trackCameraPermissionsGranted()
                    } catch let error as PermissionError {
                        if error == .denied {
                            EventTracking.trackCameraPermissionsDenied()
                            viewModel.isShowingAlertForPermissions = true
                            return
                        }
                    }
                    do {
                        try await self.cameraPermissions.requestMicrophonePermission()
                        EventTracking.trackMicrophonePermissionsGranted()
                    } catch let error as PermissionError {
                        if error == .denied {
                            EventTracking.trackMicrophonePermissionsDenied()
                        }
                    }
                    try await viewModel.saveState()
                    EventTracking.trackOnboardingFinished()
                    throw OnboardingViewError.onboardingEnded
                }, content: { _ in
                    AnyView(VStack {
                        OptionItemView(
                            title: L10n.onboardingPermissionsCameraAccess,
                            description: L10n.onboardingPermissionsCameraAccessSubheading,
                            isAvailable: true,
                            isSelected: Binding<Bool>(
                                get: { self.cameraPermissions.isCameraAccessAuthorized },
                                set: { _ in
                                })) {
                                    EventTracking.trackCameraPermissionsTapped()
                                    Task {
                                        try? await self.cameraPermissions.requestCameraPermission()
                                    }
                                }

                        OptionItemView(
                            title: L10n.onboardingPermissionsMicrophoneAccess,
                            description: L10n.onboardingPermissionsMicrophoneAccessSubheading,
                            isAvailable: true,
                            isSelected: Binding<Bool>(
                                get: { self.cameraPermissions.isMicrophoneAccessAuthorized },
                                set: { _ in
                                })) {
                                    EventTracking.trackMicrophonePermissionsTapped()
                                    Task {
                                        try? await self.cameraPermissions.requestMicrophonePermission()
                                    }
                                }
                    }.padding(10)
                    )
                })

        case .finished:
            return .init(
                screen: flow,
                title: L10n.doneOnboarding,
                subheading: "",
                image: nil,
                bottomButtonTitle: L10n.done,
                bottomButtonAction: {
                    try await viewModel.saveState()
                    EventTracking.trackOnboardingFinished()
                    throw OnboardingViewError.onboardingEnded
                }) { _ in
                    AnyView(
                        VStack(alignment: .leading, spacing: 15.0) {
                            Text(L10n.storageExplanationHeader)
                                .fontType(.medium)
                            Text(L10n.storageExplanation)
                                .fontType(.pt14)

                        })
                }
        default:
            return viewModel(for: .intro)
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
                    .fontType(.pt18)
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
        MainOnboardingView(viewModel: OnboardingViewModel<DemoAlbumManager>(onboardingManager: DemoOnboardingManager(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), settingsManager: SettingsManager()), keyManager: DemoKeyManager(), authManager: DemoAuthManager()))
            .preferredColorScheme(.dark)
            .previewDevice("iPhone 8")
            .background(Color.background)
    }
}
