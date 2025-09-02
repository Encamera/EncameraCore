//
//  OnboardingHostingView.swift
//  Encamera
//
//  Created by Alexander Freas on 04.02.24.
//

import SwiftUI
import EncameraCore
import Combine

class OnboardingHostingViewModel<GenericAlbumManaging: AlbumManaging>: ObservableObject {
    @Published var currentOnboardingImageIndex = 0
    @MainActor
    @Published var useBiometrics: Bool = false
    @MainActor
    @Published var generalError: Error?
    @Published var pinCode1: String = ""
    @Published var pinCode2: String = ""
    @Published var existingPassword: String = ""
    @Published var pinCodeError: String?
    @Published var showAddAlbumModal: Bool = false
    @Published var passwordState: PasswordValidation?

    var keyManager: KeyManager
    private var finishedAction: () -> ()
    private var onboardingManager: OnboardingManaging
    private var albumManager: GenericAlbumManaging
    private var passwordValidator = PasswordValidator()
    private var cancellables = Set<AnyCancellable>()
    private var authManager: AuthManager
    var enteredPinCode: String = ""
    var hasAlbums: Bool {
        albumManager.loadAlbumsFromFilesystem()
        return albumManager.albums.count > 0
    }

    var areBiometricsAvailable: Bool {
        authManager.canAuthenticateWithBiometrics
    }


    @MainActor
    func authWithBiometrics() async throws {
        do {
            try await authManager.authorizeWithBiometrics()
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

    init(onboardingManager: OnboardingManaging,
         keyManager: KeyManager,
         authManager: AuthManager,
         finishedAction: @escaping () -> ()
    ) {
        self.onboardingManager = onboardingManager
        self.keyManager = keyManager
        self.authManager = authManager
        self.finishedAction = finishedAction
        self.albumManager = GenericAlbumManaging(keyManager: keyManager)
    }

    func saveAlbum(name: String) {
        _ = try? albumManager.create(name: name, storageOption: .local)
    }

    @discardableResult func validatePassword() throws -> PasswordValidation {
        let state = PasswordValidator.validatePasswordPair(enteredPinCode, password2: enteredPinCode, type: .pinCode(length: AppConstants.defaultPinCodeLength))
        passwordState = state

        if state != .valid {
            throw OnboardingViewError.passwordInvalid
        }
        return state
    }

    func doesPinCodeMatchNew(pinCode: String) -> Bool {
        debugPrint("Pincode", pinCode, "==", enteredPinCode)
        if pinCode.count != enteredPinCode.count {
            return false
        }
        return pinCode == enteredPinCode
    }

    @MainActor func savePassword() throws {
        do {
            let validation = try validatePassword()
            if validation == .valid && existingPassword.isEmpty == false {
                try keyManager.changePassword(newPassword: enteredPinCode, existingPassword: existingPassword, type: .pinCode(length: AppConstants.defaultPinCodeLength))
            } else if validation == .valid {
                try keyManager.setPassword(enteredPinCode, type: .pinCode(length: AppConstants.defaultPinCodeLength))
            } else {
                throw OnboardingViewError.passwordInvalid
            }
        } catch {
            try handle(error: error)
        }
    }

    @MainActor
    func handle(error: Error) throws {

        generalError = error

        throw error
    }


    func finishOnboarding(albumName: String?) async throws {
            do {
                if !enteredPinCode.isEmpty {
                    try await savePassword()
                    try authManager.authorize(with: enteredPinCode, using: keyManager)
                } else if await useBiometrics {
                    try await authManager.authorizeWithBiometrics()
                } else {
                    fatalError("No password or biometrics")
                }

                let keys = try? keyManager.storedKeys()
                if keys == nil || keys?.isEmpty ?? false {
                    let _ = try keyManager.generateKeyUsingRandomWords(name: AppConstants.defaultKeyName)
                }
                var album: Album?
                if let albumName = albumName {
                    album = try albumManager.create(name: albumName, storageOption: .local)
                } else if let firstAlbum = albumManager.albums.first {
                    album = firstAlbum
                }
                albumManager.currentAlbum = album

                try await onboardingManager.saveOnboardingState(.completed, settings: SavedSettings(useBiometricsForAuth: await useBiometrics))
                UserDefaultUtils.set(true, forKey: .showCurrentAlbumOnLaunch)
            } catch {
                debugPrint("Could not finish onboarding: \(error)")
                try? await handle(error: error)
            }
            authManager.isAuthenticatedPublisher
            .sink { [weak self] isAuthenticated in
                Task { @MainActor in
                    EventTracking.trackOnboardingFinished(new: true)
                }
                self?.finishedAction()

            }.store(in: &cancellables)
    }


    @MainActor
    func checkExistingPasswordAndAuth() throws {
        do {
            let existingPasswordCorrect = try keyManager.checkPassword(existingPassword)
            if existingPasswordCorrect == false {
                generalError = OnboardingViewError.passwordInvalid
                throw OnboardingViewError.passwordInvalid
            }
        } catch {
            generalError = OnboardingViewError.passwordInvalid
            throw OnboardingViewError.passwordInvalid
        }
    }
}

struct OnboardingHostingView<GenericAlbumManaging: AlbumManaging>: View {

    @StateObject var viewModel: OnboardingHostingViewModel<GenericAlbumManaging>
    @State var path: NavigationPath = .init()

    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationStack(path: $path) {
            handleNavigationFor(destination: .intro)
            .navigationDestination(for: OnboardingFlowScreen.self) { screen in
                handleNavigationFor(destination: screen)
            }
        }
    }
    
    @ViewBuilder
    func handleNavigationFor(destination: OnboardingFlowScreen) -> some View {

        switch destination {
        case .intro:
            NewOnboardingView(viewModel: .init(
                screen: .intro,
                showTopBar: false,
                bottomButtonTitle: viewModel.currentOnboardingImageIndex < 2 ? L10n.next : L10n.getStartedButtonText,
                bottomButtonAction: {
                    if viewModel.currentOnboardingImageIndex < 2 {
                        viewModel.currentOnboardingImageIndex += 1
                    } else {
                        if viewModel.keyManager.passwordExists() {
                            path.append(OnboardingFlowScreen.enterExistingPassword)
                        } else if viewModel.areBiometricsAvailable {
                            path.append(OnboardingFlowScreen.biometricsWithPin)
                        } else {
                            path.append(OnboardingFlowScreen.setPinCode)
                        }
                    }
                }, content:  { _ in
                    AnyView(
                        VStack {
                            OnboardingImageCarousel(currentScrolledToImage: $viewModel.currentOnboardingImageIndex)
                            Spacer()
                        }.padding(0)
                    )
                }))
        case .enterExistingPassword:
            let model = PasswordEntryViewModel(keyManager: viewModel.keyManager, stateUpdate: { state in
                guard case .valid(let existingPassword) = state else {
                    return
                }
                viewModel.existingPassword = existingPassword
                do {
                    try viewModel.checkExistingPasswordAndAuth()
                    path.append(OnboardingFlowScreen.biometricsWithPin)
                } catch {
                    debugPrint("Error checking existing password")
                }
            })

            NewOnboardingView(viewModel: .init(
                screen: .enterExistingPassword,
                title: L10n.enterPassword,
                subheading: L10n.youHaveAnExistingPasswordForThisDevice, image: Image(systemName: "key.fill"), bottomButtonTitle: L10n.next, bottomButtonAction: {
                    try viewModel.checkExistingPasswordAndAuth()
                    path.append(OnboardingFlowScreen.biometricsWithPin)
                }, content:  { _ in
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
                            }.textButton()
                        }
                    )
                }))

        case .biometricsWithPin:
            NewOnboardingView(viewModel:
                    .init(
                        screen: destination,
                        showTopBar: false,
                        bottomButtonTitle: viewModel.areBiometricsAvailable ? L10n.enableFaceID : L10n.openSettings,
                        bottomButtonAction: {
                            try await viewModel.authWithBiometrics()
                            EventTracking.trackOnboardingBiometricsEnabled(newOnboarding: true)
                            path.append(OnboardingFlowScreen.finished)
                        }, secondaryButtonTitle: L10n.usePasscodeInstead,
                        secondaryButtonAction: {
                            path.append(OnboardingFlowScreen.setPinCode)
                        },
                        content: { _ in

                            AnyView(
                                VStack(alignment: .center) {
                                    ZStack {
                                        Image("Onboarding-Shield")
                                        Rectangle()
                                            .foregroundColor(.clear)
                                            .frame(width: 96, height: 96)
                                            .background(Color.actionYellowGreen.opacity(0.1))
                                            .cornerRadius(24)
                                    }
                                    Spacer().frame(height: 32)
                                    Text(L10n.selectLoginMethod)
                                        .fontType(.pt24, weight: .bold)
                                    Spacer().frame(height: 12)
                                    Text(L10n.loginMethodDescription)
                                        .fontType(.pt14)
                                        .multilineTextAlignment(.center)
                                }.frame(width: 290)
                            )
                        })
            ).onAppear {
                // handles the case where the user goes back
                // after entering a pin code once
                viewModel.pinCode1 = ""
                viewModel.enteredPinCode = ""
            }
        case .setPinCode:

            NewOnboardingView(viewModel:
                    .init(
                        screen: destination,
                        showTopBar: true,
                        content: { _ in
                            AnyView(
                                VStack(alignment: .center) {
                                    ZStack {
                                        Image("Onboarding-PinKey")
                                        Rectangle()
                                            .foregroundColor(.clear)
                                            .frame(width: 96, height: 96)
                                            .background(Color.actionYellowGreen.opacity(0.1))
                                            .cornerRadius(24)
                                    }
                                    Spacer().frame(height: 32)

                                    Text(L10n.setPinCode)
                                        .fontType(.pt24, weight: .bold)
                                    Spacer().frame(height: 12)

                                    Text(L10n.setPinCodeSubtitle)
                                        .fontType(.pt14)
                                        .lineLimit(2, reservesSpace: true)
                                        .multilineTextAlignment(.center)
                                        .pad(.pt64, edge: .bottom)
                                    PinCodeView(pinCode: $viewModel.pinCode1, pinLength: .four)
                                }.frame(width: 290)
                            )
                        })
            ).onChange(of: viewModel.pinCode1) { oldValue, newValue in
                if newValue.count == AppConstants.defaultPinCodeLength.rawValue {
                    viewModel.enteredPinCode = newValue
                    path.append(OnboardingFlowScreen.confirmPinCode)
                }
            }.onAppear {
                // handles the case where the user goes back
                // after entering a pin code once

                viewModel.pinCodeError = nil
                viewModel.pinCode1 = ""
                viewModel.enteredPinCode = ""

            }
        case .confirmPinCode:
            NewOnboardingView(viewModel:
                    .init(
                        screen: destination,
                        showTopBar: true,
                        secondaryButtonAction: {
                            if viewModel.doesPinCodeMatchNew(pinCode: viewModel.pinCode2) {
                                viewModel.enteredPinCode = viewModel.pinCode2
                                path.append(OnboardingFlowScreen.finished)
                            } else {
                                viewModel.pinCodeError = L10n.pinCodeMismatch
                                // add haptic feedback
                            }
                        },
                        content: { _ in
                            AnyView(
                                VStack(alignment: .center) {
                                    ZStack {
                                        Image("Onboarding-PinKey")
                                        Rectangle()
                                            .foregroundColor(.clear)
                                            .frame(width: 96, height: 96)
                                            .background(Color.actionYellowGreen.opacity(0.1))
                                            .cornerRadius(24)
                                    }
                                    Spacer().frame(height: 32)
                                    Text(L10n.confirmPinCode)
                                        .fontType(.pt24, weight: .bold)
                                    Spacer().frame(height: 12)
                                    Text(L10n.repeatPinCodeSubtitle)
                                        .fontType(.pt14)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2, reservesSpace: true)
                                        .pad(.pt64, edge: .bottom)
                                    PinCodeView(pinCode: $viewModel.pinCode2, pinLength: AppConstants.defaultPinCodeLength)
                                    if let pinCodeError = viewModel.pinCodeError {
                                        Text(pinCodeError).alertText()
                                    }
                                }.frame(width: 290)

                            )
                        })
            )
            .onChange(of: viewModel.pinCode2) { oldValue, newValue in
                if viewModel.doesPinCodeMatchNew(pinCode: newValue) {
                    viewModel.pinCodeError = nil
                    path.append(OnboardingFlowScreen.finished)
                } else if newValue.count == AppConstants.defaultPinCodeLength.rawValue {
                    viewModel.pinCodeError = "Pin code does not match"
                    viewModel.pinCode2 = ""
                }
            }


        case .finished:

            NewOnboardingView(viewModel:
                    .init(
                        screen: destination,
                        showTopBar: false,
                        bottomButtonTitle: viewModel.hasAlbums ? L10n.letsGo : L10n.createFirstAlbum,
                        bottomButtonAction: {
                            if viewModel.hasAlbums {
                                Task {
                                    try await viewModel.finishOnboarding(albumName: nil)
                                    presentationMode.wrappedValue.dismiss()
                                }
                            } else {
                                viewModel.showAddAlbumModal = true
                            }
                        },
                        secondaryButtonAction: {
                            path.append(OnboardingFlowScreen.finished)
                        },
                        content: { _ in
                            AnyView(
                                VStack(alignment: .center) {
                                    ZStack {
                                        Image("Onboarding-FinishedCheck")
                                        Rectangle()
                                            .foregroundColor(.clear)
                                            .frame(width: 96, height: 96)
                                            .background(Color.actionYellowGreen.opacity(0.1))
                                            .cornerRadius(24)
                                    }
                                    Spacer().frame(height: 32)
                                    Text(L10n.finishedReadyToUseEncamera)
                                        .fontType(.pt24, weight: .bold)
                                        .multilineTextAlignment(.center)
                                    Spacer().frame(height: 12)
                                    Text(viewModel.hasAlbums ? "" : L10n.finishedSubtitle)
                                        .fontType(.pt14)
                                        .multilineTextAlignment(.center)
                                        .pad(.pt64, edge: .bottom)
                                }.frame(width: 290)

                            )
                        })
            )
            .sheet(isPresented: $viewModel.showAddAlbumModal, content: {
                AddAlbumModal { albumName in
                    Task {
                        try await viewModel.finishOnboarding(albumName: albumName)
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            })
        default:
            fatalError("Not implemented")
        }
    }

}




#Preview {
    OnboardingHostingView<DemoAlbumManager>(viewModel: .init(onboardingManager: DemoOnboardingManager(), keyManager: DemoKeyManager(), authManager: DemoAuthManager(), finishedAction: {}))
}
