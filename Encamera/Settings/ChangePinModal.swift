//
//  ChangePinModal.swift
//  Encamera
//
//  Created by Alexander Freas on 28.02.24.
//

import SwiftUI
import EncameraCore

class ChangePinModalViewModel: ObservableObject {

    @Published var pinCode1: String = ""
    @Published var pinCode2: String = ""
    @Published var enteredPinCode: String = ""
    @Published var pinCodeError: String?
    @Published var showPasswordChangedAlert: Bool = false

    var completedAction: (() -> Void)?
    private var authManager: AuthManager
    private var keyManager: KeyManager


    func doesPinCodeMatchNew(pinCode: String) -> Bool {
        return PasswordValidator.validatePasswordPair(pinCode, password2: enteredPinCode) == .valid
    }

    init(authManager: AuthManager, keyManager: KeyManager, completedAction: (() -> Void)? = nil) {
        self.authManager = authManager
        self.keyManager = keyManager
        self.completedAction = completedAction
    }

    @discardableResult func validatePassword() throws -> PasswordValidation {
        let state = PasswordValidator.validatePasswordPair(enteredPinCode, password2: enteredPinCode)

        if state != .valid {
            throw OnboardingViewError.passwordInvalid
        }
        return state
    }



    @MainActor func savePassword() throws {
        let validation = try validatePassword()
        if validation == .valid  {
            try keyManager.setOrUpdatePassword(enteredPinCode)
        } else {
            throw OnboardingViewError.passwordInvalid
        }
    }

}

struct ChangePinModal: View {

    @StateObject var viewModel: ChangePinModalViewModel
    @State private var path: NavigationPath = .init()
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {


                NewOnboardingView(viewModel:
                        .init(
                            screen: .setPinCode,
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
                                            .lineLimit(2, reservesSpace: true)
                                            .multilineTextAlignment(.center)
                                            .pad(.pt64, edge: .bottom)
                                        PinCodeView(pinCode: $viewModel.pinCode1, pinActionButtonTitle: L10n.next, confirmPinAction: { pinCode in
                                            viewModel.enteredPinCode = pinCode
                                            path.append(OnboardingFlowScreen.confirmPinCode)

                                        })
                                    }.frame(width: 290)

                                )
                            }))
                .onAppear {
                    viewModel.pinCodeError = nil
                }

                .navigationDestination(for: OnboardingFlowScreen.self) { screen in
                    if screen == .confirmPinCode {
                        NewOnboardingView(viewModel:
                                .init(
                                    screen: .confirmPinCode,
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
                                                Text(L10n.confirmPinCode)
                                                    .fontType(.pt24, weight: .bold)
                                                Spacer().frame(height: 12)
                                                Text(L10n.repeatPinCodeSubtitle)
                                                    .fontType(.pt14)
                                                    .multilineTextAlignment(.center)
                                                    .lineLimit(2, reservesSpace: true)
                                                    .pad(.pt64, edge: .bottom)
                                                PinCodeView(pinCode: $viewModel.pinCode2, pinActionButtonTitle: L10n.savePinCode, confirmPinAction: { pinCode in
                                                    if viewModel.doesPinCodeMatchNew(pinCode: pinCode) {
                                                        viewModel.pinCodeError = nil
                                                        do {
                                                            try viewModel.savePassword()
                                                            viewModel.showPasswordChangedAlert = true
                                                        } catch {
                                                            viewModel.pinCodeError = "Error saving password"
                                                        }

                                                    } else {
                                                        viewModel.pinCodeError = L10n.pinCodeMismatch
                                                        viewModel.pinCode2 = ""
                                                    }
                                                })
                                                if let pinCodeError = viewModel.pinCodeError {
                                                    Text(pinCodeError).alertText()
                                                }
                                            }.frame(width: 290)

                                        )
                                    })
                        )
                    }
                }
            }

        }
        .alert(isPresented: $viewModel.showPasswordChangedAlert) {
            Alert(title: Text(L10n.pinSuccessfullyChanged), message: Text(L10n.makeSureYouRememberYourPin), dismissButton: .default(Text(L10n.ok), action: {
                presentationMode.wrappedValue.dismiss()
                viewModel.completedAction?()
            }))
        }
        .overlay(alignment: .topLeading) {
            DismissButton {
                presentationMode.wrappedValue.dismiss()
            }.padding(20)
        }
    }
}

#Preview {
    Color.green.sheet(isPresented: .constant(true)) {
        ChangePinModal(viewModel: .init(authManager: DemoAuthManager(), keyManager: DemoKeyManager()))
    }
}
