import SwiftUI
import EncameraCore
import Foundation
import Security

class AuthenticationMethodViewModel: ObservableObject {
    enum AlertType {
        case changeConfirmation
        case clearPasswordConfirmation
    }
    
    @Published var selectedOption: PasscodeType? = nil
    @Published var useFaceID: Bool = false
    @Published var alertForSelection: PasscodeType?
    @Published var modalForSelection: PasscodeType?
    @Published var showPasswordModal = false
    @Published var pinLength: Int = 4
    @Published var newOption: PasscodeType?

    // Alert state
    @Published var activeAlert: AlertType? = nil
    
    var authManager: AuthManager
    var keyManager: KeyManager

    init(authManager: AuthManager, keyManager: KeyManager) {
        self.authManager = authManager
        self.keyManager = keyManager
    }

    func selectOption(_ option: PasscodeType) {
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
                
                Text(L10n.chooseYourLoginMethod)
                    .fontType(.pt12)
                    .foregroundColor(.gray)
                    .padding(.horizontal)
                
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
                            Image(systemName: viewModel.selectedOption == option ? "circle.fill" : "circle")
                                .foregroundColor(viewModel.selectedOption == option ? .blue : .gray)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                        .onTapGesture {
                            viewModel.selectOption(option)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .screenBlocked()

            Spacer()
        }
        .sheet(isPresented: $viewModel.showPinModal) {
            ChangePinModal(viewModel: .init(
                authManager: viewModel.authManager,
                keyManager: viewModel.keyManager,
                pinLength: viewModel.pinLength,
                completedAction: {
                    // If PIN setup is completed, make sure it's selected
                    viewModel.authManager.addAuthenticationMethod(.pinCode)
                }
            ))
        }
        .sheet(isPresented: $viewModel.showPasswordModal) {
            SetPasswordView(viewModel: .init(
                authManager: viewModel.authManager,
                keyManager: viewModel.keyManager,
                completedAction: {
                    // If password setup is completed, make sure it's selected
                    viewModel.authManager.addAuthenticationMethod(.password)
                }
            ))
        }
        .alert(isPresented: Binding<Bool>(
            get: { viewModel.activeAlert != nil },
            set: { if !$0 { viewModel.activeAlert = nil } }
        )) {
            alert(for: viewModel.activeAlert)
        }
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ViewHeader(
                    title: L10n.authenticationMethod,
                    isToolbar: true,
                    textAlignment: .center,
                    titleFont: .pt18
                )
                .frame(maxWidth: .infinity)
            }
        }
        .gradientBackground()
    }
    
    private func alert(for alertType: PasscodeType?) -> Alert {
        switch alertType {
        case .pinCode(length: let _):
            return Alert(
                title: Text(L10n.changeAuthenticationMethod),
                message: Text(L10n.ChangingYourAuthenticationMethodWillRequireSettingUpANewPINOrPassword.wouldYouLikeToContinue),
                primaryButton: .cancel(Text(L10n.cancel)) {
                    viewModel.newOption = nil
                },
                secondaryButton: .default(Text(L10n.continue)) {
                    viewModel.applyOptionChange()
                }
            )
        case .none:
            return Alert(
                title: Text(L10n.clearPassword),
                message: Text(L10n.ThisWillRemoveAllAuthenticationMethods.YourDataWillRemainButYouLlNeedToSetUpANewPINOrPasswordNextTimeYouOpenTheApp.continue),
                primaryButton: .cancel(Text(L10n.cancel)),
                secondaryButton: .destructive(Text(L10n.clear)) {
                    viewModel.authManager.removeAllAuthenticationMethods()
                    viewModel.selectedOption = nil
                }
            )
        case .none:
            return Alert(title: Text(""))
        }
    }
}

#Preview {
    NavigationStack {
        AuthenticationMethodView(authManager: DemoAuthManager(), keyManager: DemoKeyManager())
    }
}

