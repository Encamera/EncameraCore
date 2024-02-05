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
}

struct NewOnboardingHostingView<GenericAlbumManaging: AlbumManaging>: View {

    @StateObject var viewModel: OnboardingViewModel<GenericAlbumManaging>

    var body: some View {
        NavigationStack {
            NewOnboardingView(viewModel: NewOnboardingViewViewModel.init(
                screen: .intro,
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
                            ImageCarousel(currentScrolledToImage: $viewModel.currentOnboardingImageIndex)
                            Spacer()
                        }.padding(0)
                    )
                })
        }
        .navigationDestination(for: OnboardingFlowScreen.self) { screen in
            handleNavigationFor(destination: screen)
        }

    }
    
    @ViewBuilder
    func handleNavigationFor(destination: OnboardingFlowScreen) -> some View {
        switch destination {
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
                            EventTracking.trackOnboardingBiometricsEnabled()
                        }, secondaryButtonTitle: L10n.usePINInstead,
                        secondaryButtonAction: {

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
        //                            ImageCarousel(currentScrolledToImage: $viewModel.currentOnboardingImageIndex)
        //                            Spacer()
                                }.frame(width: 290)
                            )
                        })
            )
        case .setPinCode:
            fatalError("implement")
        case .finished:
            fatalError("implement")
        default:
            fatalError("Not implemented")
        }
    }

}

#Preview {
    NewOnboardingView(viewModel: .init(screen: .intro, bottomButtonTitle: "Next"))
}
