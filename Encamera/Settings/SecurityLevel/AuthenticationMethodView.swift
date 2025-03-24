import SwiftUI
import EncameraCore
import Foundation
import Security

class AuthenticationMethodViewModel: ObservableObject {

    @Published var selectedOption: PasscodeType? = nil
    @Published var useFaceID: Bool = false
    @Published var alertForSelection: PasscodeType?
    @Published var modalForSelection: PasscodeType?

    var authManager: AuthManager
    var keyManager: KeyManager

    init(authManager: AuthManager, keyManager: KeyManager) {
        self.authManager = authManager
        self.keyManager = keyManager
        self.selectedOption = keyManager.passcodeType
    }

    func selectOption(_ option: PasscodeType?) {
        selectedOption = option
    }

    func startPasscodeChange(_ option: PasscodeType?) {
        if option == selectedOption {
            return
        }
        alertForSelection = option
    }

}

struct AuthenticationMethodView: View {
    @StateObject private var viewModel: AuthenticationMethodViewModel
    @Environment(\.presentationMode) private var presentationMode
    
    init(authManager: AuthManager, keyManager: KeyManager) {
        _viewModel = StateObject(wrappedValue: AuthenticationMethodViewModel(authManager: authManager, keyManager: keyManager))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.selectLoginMethod)
                    .fontType(.pt14, weight: .bold)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
                    .padding(.top, 8)
                // Authentication options as radio buttons
                VStack(spacing: 16) {
                    ForEach(PasscodeType.allCases) { option in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.textDescription)
                                    .fontType(.pt16, weight: .medium)
                            }
                            
                            Spacer()
                            
                            // Radio button style
                            Image(systemName: viewModel.selectedOption == option ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(viewModel.selectedOption == option ? Color.actionYellowGreen : .gray)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .frame(height: 64)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                        .onTapGesture {
                            viewModel.alertForSelection = option
                        }
                    }
                }
                .padding(.horizontal)
            }
            .screenBlocked()

            Spacer()
        }
        .sheet(isPresented: Binding<Bool>(get: {
            viewModel.modalForSelection != nil
        }, set: { type in
            if type == false {
                viewModel.modalForSelection = nil
            }
        })) {
            let selection = viewModel.modalForSelection
            switch selection {
            case .pinCode(let length):
                ChangePinModal(viewModel: .init(
                    keyManager: viewModel.keyManager,
                    pinLength: length,
                    completedAction: {
                        viewModel.selectOption(selection)
                    }
                ))
            case .password:
                PasswordEntry(viewModel: .init(
                    keyManager: viewModel.keyManager,
                    stateUpdate: { _ in },
                    completedAction: {
                        viewModel.selectOption(selection)
                    }
                ))

            case .some, nil:
                EmptyView()
            }
        }
        .alert(isPresented: Binding<Bool>(
            get: { viewModel.alertForSelection != nil },
            set: { if !$0 { viewModel.alertForSelection = nil } }
        )) {
            alert(for: viewModel.alertForSelection)
        }
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItemGroup(placement: .principal, content: {

                ViewHeader(
                    title: L10n.authenticationMethod,
                    isToolbar: true,
                    textAlignment: .leading,
                    titleFont: .pt18
                )
            })
        }
        .gradientBackground()
    }

    private func alert(for alertType: PasscodeType?) -> Alert {
        switch alertType {
        case .pinCode, .password:
            return Alert(
                title: Text(L10n.changeAuthenticationMethod),
                message: Text(L10n.ChangingYourAuthenticationMethodWillRequireSettingUpANewPINOrPassword.wouldYouLikeToContinue),
                primaryButton: .cancel(Text(L10n.cancel)) {
                },
                secondaryButton: .default(Text(L10n.continue)) {
                    viewModel.modalForSelection = alertType
                }
            )
        case PasscodeType.none?:
            if viewModel.authManager.useBiometricsForAuth {

                return Alert(
                    title: Text(L10n.clearPassword),
                    message: Text(L10n.removePasscode),
                    primaryButton: .cancel(Text(L10n.cancel)),
                    secondaryButton: .destructive(Text(L10n.clear)) {
                        try? viewModel.keyManager.clearPassword()
                        viewModel.selectedOption = PasscodeType.none
                    }
                )
            } else {
                return Alert(
                    title: Text(L10n.cannotClearTitle),
                    message: Text(L10n.cannotClearMessage),
                    dismissButton: .default(Text(L10n.ok))
                )
            }
        case nil:
            return Alert(title: Text(""))
        }
    }
}

#Preview {
    NavigationStack {
        AuthenticationMethodView(authManager: DemoAuthManager(), keyManager: DemoKeyManager())
    }
}

