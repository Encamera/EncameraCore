//
//  NewOnboardingHostingView.swift
//  Encamera
//
//  Created by Alexander Freas on 04.02.24.
//

import SwiftUI
import EncameraCore
import Combine

class NewOnboardingViewModel<GenericAlbumManaging: AlbumManaging>: ObservableObject {
    @Published var currentOnboardingImageIndex = 0
    @MainActor
    @Published var useBiometrics: Bool = false
    @MainActor
    @Published var generalError: Error?
    @Published var pinCode1: String = ""
    @Published var pinCode2: String = ""
    @Published var pinCodeError: String?
    @Published var showAddAlbumModal: Bool = false
    @Published var passwordState: PasswordValidation?

    private var keyManager: KeyManager
    private var finishedAction: () -> ()
    private var onboardingManager: OnboardingManaging
    private var albumManager: GenericAlbumManaging?
    private var passwordValidator = PasswordValidator()
    private var cancellables = Set<AnyCancellable>()
    private var authManager: AuthManager


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

    init(onboardingManager: OnboardingManaging,
         keyManager: KeyManager,
         authManager: AuthManager,
         finishedAction: @escaping () -> ()
    ) {
        self.onboardingManager = onboardingManager
        self.keyManager = keyManager
        self.authManager = authManager
        self.finishedAction = finishedAction
    }

    func saveAlbum(name: String) {
        _ = try? albumManager?.create(name: name, storageOption: .local)
    }

    @discardableResult func validatePassword() throws -> PasswordValidation {
        let state = PasswordValidator.validatePasswordPair(pinCode1, password2: pinCode2)
        passwordState = state

        if state != .valid {
            throw OnboardingViewError.passwordInvalid
        }
        return state
    }

    func doesPinCodeMatchNew(pinCode: String) -> Bool {
        if pinCode.count != pinCode1.count {
            return false
        }
        return pinCode == pinCode1
    }

    @MainActor func savePassword() throws {
        do {
            let validation = try validatePassword()
            if validation == .valid {
                try keyManager.setPassword(pinCode1)
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


    func finishOnboarding(albumName: String) {
        Task {
            do {
                if !pinCode1.isEmpty {
                    try await savePassword()
                    try authManager.authorize(with: pinCode1, using: keyManager)
                } else {
                    try await authManager.authorizeWithBiometrics()
                }
                UserDefaultUtils.set(true, forKey: .usesPinPassword)

                let keys = try? keyManager.storedKeys()
                if keys == nil || keys?.isEmpty ?? false {
                    let _ = try keyManager.generateKeyUsingRandomWords(name: AppConstants.defaultKeyName)
                }

                var albumManager = GenericAlbumManaging(keyManager: keyManager)
                let album = try? albumManager.create(name: albumName, storageOption: .local)
                albumManager.currentAlbum = album
                self.albumManager = albumManager

                try await onboardingManager.saveOnboardingState(.completed, settings: SavedSettings(useBiometricsForAuth: await useBiometrics))
                UserDefaultUtils.set(true, forKey: .showCameraOnLaunch)
            } catch {
                debugPrint("Could not finish onboarding: \(error)")
                try? await handle(error: error)
            }
            authManager.isAuthenticatedPublisher.sink { [weak self] isAuthenticated in
                EventTracking.trackOnboardingFinished(new: true)
                self?.finishedAction()

            }.store(in: &cancellables)
            if await useBiometrics {
                Task {
                    do {
                        try await authManager.authorizeWithBiometrics()
                    } catch {
                        debugPrint("Could not authorize with biometrics")
                    }
                }
            } else {
                do {
                    try authManager.authorize(with: pinCode1, using: keyManager)
                } catch {
                    debugPrint("Could not authorize")
                }
            }

        }
    }
}

struct NewOnboardingHostingView<GenericAlbumManaging: AlbumManaging>: View {

    @StateObject var viewModel: NewOnboardingViewModel<GenericAlbumManaging>
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
                        path.append(OnboardingFlowScreen.biometricsWithPin)
                    }
                }, content:  { _ in
                    AnyView(
                        VStack {
                            ImageCarousel(currentScrolledToImage: $viewModel.currentOnboardingImageIndex)
                            Spacer()
                        }.padding(0)
                    )
                }))
        case .enterExistingPassword:
            fatalError("implement")
        case .biometricsWithPin:
            NewOnboardingView(viewModel:
                    .init(
                        screen: destination,
                        showTopBar: true,
                        bottomButtonTitle: L10n.enableFaceID,
                        bottomButtonAction: {
                            try await viewModel.authWithBiometrics()
                            EventTracking.trackOnboardingBiometricsEnabled(newOnboarding: true)
                            path.append(OnboardingFlowScreen.finished)
                        }, secondaryButtonTitle: L10n.usePINInstead,
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
            )
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
                                        .multilineTextAlignment(.center)
                                        .pad(.pt64, edge: .bottom)
                                    PinCodeView(pinCode: $viewModel.pinCode1, pinLength: AppConstants.pinCodeLength)
                                }.frame(width: 290)

                            )
                        })
            ).onChange(of: viewModel.pinCode1) { oldValue, newValue in
                print("Pincode", oldValue, newValue)
                if newValue.count == AppConstants.pinCodeLength {
                    path.append(OnboardingFlowScreen.confirmPinCode)
                }
            }

        case .confirmPinCode:
            NewOnboardingView(viewModel:
                    .init(
                        screen: destination,
                        showTopBar: true,
                        secondaryButtonAction: {
                            path.append(OnboardingFlowScreen.finished)
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
                                    Text(L10n.setPinCode)
                                        .fontType(.pt24, weight: .bold)
                                    Spacer().frame(height: 12)
                                    Text(L10n.setPinCodeSubtitle)
                                        .fontType(.pt14)
                                        .multilineTextAlignment(.center)
                                        .pad(.pt64, edge: .bottom)
                                    if let pinCodeError = viewModel.pinCodeError {
                                        Text(pinCodeError).alertText()
                                    }
                                    PinCodeView(pinCode: $viewModel.pinCode2, pinLength: AppConstants.pinCodeLength)
                                }.frame(width: 290)

                            )
                        })
            )
            .onChange(of: viewModel.pinCode2) { oldValue, newValue in
                if viewModel.doesPinCodeMatchNew(pinCode: newValue) {
                    path.append(OnboardingFlowScreen.finished)
                } else {
                    
                }
            }


        case .finished:
            NewOnboardingView(viewModel:
                    .init(
                        screen: destination,
                        showTopBar: true,
                        bottomButtonTitle: L10n.createFirstAlbum,
                        bottomButtonAction: {
                            viewModel.showAddAlbumModal = true
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
                                    Text(L10n.finishedSubtitle)
                                        .fontType(.pt14)
                                        .multilineTextAlignment(.center)
                                        .pad(.pt64, edge: .bottom)
                                    if let pinCodeError = viewModel.pinCodeError {
                                        Text(pinCodeError).alertText()
                                    }
                                }.frame(width: 290)

                            )
                        })
            )
            .sheet(isPresented: $viewModel.showAddAlbumModal, content: {
                AddAlbumModal { albumName in
                    viewModel.finishOnboarding(albumName: albumName)
                    presentationMode.wrappedValue.dismiss()
                }
            })
        default:
            fatalError("Not implemented")
        }
    }

}




#Preview {
    NewOnboardingHostingView<DemoAlbumManager>(viewModel: .init(onboardingManager: DemoOnboardingManager(), keyManager: DemoKeyManager(), authManager: DemoAuthManager(), finishedAction: {}))
}
