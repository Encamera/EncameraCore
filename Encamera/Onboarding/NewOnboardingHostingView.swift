//
//  NewOnboardingHostingView.swift
//  Encamera
//
//  Created by Alexander Freas on 04.02.24.
//

import SwiftUI
import EncameraCore

class NewOnboardingViewModel<GenericAlbumManaging: AlbumManaging>: ObservableObject {
    @Published var currentOnboardingImageIndex = 0
    @Published var useBiometrics: Bool = false
    @MainActor
    @Published var generalError: Error?
    @Published var password1: String = ""
    @Published var password2: String = ""

    private var onboardingManager: OnboardingManaging
    private var albumManager: GenericAlbumManaging?
    private var passwordValidator = PasswordValidator()
    var keyManager: KeyManager
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

    init(onboardingManager: OnboardingManaging, keyManager: KeyManager, authManager: AuthManager) {
        self.onboardingManager = onboardingManager
        self.keyManager = keyManager
        self.authManager = authManager
    }

    func saveAlbum(name: String) {
        _ = try? albumManager?.create(name: name, storageOption: .local)
    }
}

struct NewOnboardingHostingView<GenericAlbumManaging: AlbumManaging>: View {

    @StateObject var viewModel: NewOnboardingViewModel<GenericAlbumManaging>
    @State var path: NavigationPath = .init()

    @State var pinCode1: String = ""
    @State var pinCode2: String = ""
    @State var pinCodeError: String?
    @State var showAddAlbumModal: Bool = false

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
                        showTopBar: false,
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
                        showTopBar: false,
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
                                    PinCodeView(pinCode: $pinCode1, pinLength: AppConstants.pinCodeLength)
                                }.frame(width: 290)

                            )
                        })
            ).onChange(of: pinCode1) { oldValue, newValue in
                print("Pincode", oldValue, newValue)
                if newValue.count == AppConstants.pinCodeLength {
                    path.append(OnboardingFlowScreen.confirmPinCode)
                }
            }

        case .confirmPinCode:
            NewOnboardingView(viewModel:
                    .init(
                        screen: destination,
                        showTopBar: false,
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
                                    if let pinCodeError {
                                        Text(pinCodeError).alertText()
                                    }
                                    PinCodeView(pinCode: $pinCode2, pinLength: AppConstants.pinCodeLength)
                                }.frame(width: 290)

                            )
                        })
            )
            .onChange(of: pinCode2) { oldValue, newValue in
                if newValue == pinCode1 {
                    path.append(OnboardingFlowScreen.finished)
                } else if pinCode2.count == AppConstants.pinCodeLength && pinCode1 != pinCode2 {
                    pinCodeError = L10n.pinCodeDoesNotMatch
                    pinCode2 = ""
                }
            }


        case .finished:
            NewOnboardingView(viewModel:
                    .init(
                        screen: destination,
                        showTopBar: false,
                        bottomButtonTitle: L10n.createFirstAlbum,
                        bottomButtonAction: {
                            showAddAlbumModal = true
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
                                    if let pinCodeError {
                                        Text(pinCodeError).alertText()
                                    }
                                }.frame(width: 290)

                            )
                        })
            )
            .sheet(isPresented: $showAddAlbumModal, content: {
                AddAlbumModal { albumName in
                    viewModel.saveAlbum(name: albumName)
                    presentationMode.wrappedValue.dismiss()
                }
            })
        default:
            fatalError("Not implemented")
        }
    }

}




#Preview {
    NewOnboardingHostingView<DemoAlbumManager>(viewModel: .init(onboardingManager: DemoOnboardingManager(), keyManager: DemoKeyManager(), authManager: DemoAuthManager()))
}
