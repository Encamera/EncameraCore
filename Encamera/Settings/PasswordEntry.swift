//
//  PasswordEntry.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import SwiftUI
import Combine
import EncameraCore

enum PasswordEntryState: Equatable {
    case empty
    case invalid
    case valid(String)
}

enum PasswordEntryScreen: Hashable {
    case enterPassword
    case confirmPassword
}

class PasswordEntryViewModel: ObservableObject {
    typealias PasswordStateUpdate = (PasswordEntryState) -> Void
    @Published var password1: String = ""
    @Published var password2: String = ""
    @Published var enteredPassword: String = ""
    @Published var passwordError: String?
    var placeholderText = L10n.password
    var confirmPlaceholderText = L10n.repeatPassword
    var keyManager: KeyManager
    var stateUpdate: PasswordStateUpdate
    @Published var attempts: Int = 0
    @Published var offset: CGSize = .zero
    @Published var passwordState: PasswordEntryState
    @Published var showSuccessAlert = false
    private var cancellables = Set<AnyCancellable>()
    var completedAction: (() -> Void)?

    init(placeholderText: String = L10n.password, 
         confirmPlaceholderText: String = L10n.repeatPassword,
         keyManager: KeyManager,
         stateUpdate: @escaping PasswordStateUpdate,
         completedAction: (() -> Void)? = nil) {
        self.placeholderText = placeholderText
        self.confirmPlaceholderText = confirmPlaceholderText
        self.stateUpdate = stateUpdate
        self.keyManager = keyManager
        self.passwordState = .empty
        self.completedAction = completedAction
    }
    
    func doesPasswordMatch(password: String) -> Bool {
        return PasswordValidator.validatePasswordPair(password, password2: enteredPassword, type: .password) == .valid
    }
    
    func validatePasswordAndNotify() {
        do {
            try keyManager.setOrUpdatePassword(enteredPassword, type: .password)
            passwordState = .valid(enteredPassword)

            stateUpdate(passwordState)
            showSuccessAlert = true
            completedAction?()
        } catch {
            passwordState = .invalid
            stateUpdate(passwordState)
            passwordError = L10n.failedToSavePassword
        }
    }
}

struct Shake: GeometryEffect {
    var amount: CGFloat = 10
    var shakesPerUnit = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX:
                                                amount * sin(animatableData * .pi * CGFloat(shakesPerUnit)),
                                                y: 0))
    }
}

struct PasswordEntry: View {
    
    @StateObject var viewModel: PasswordEntryViewModel
    @State private var path: NavigationPath = .init()
    @Environment(\.presentationMode) private var presentationMode
    @FocusState private var isInputFieldFocused: Bool
    
    private var pinKeyImage: some View {
        ZStack {
            Image("Onboarding-PinKey")
            Rectangle()
                .foregroundColor(.clear)
                .frame(width: 96, height: 96)
                .background(Color.actionYellowGreen.opacity(0.1))
                .cornerRadius(24)
        }
    }
    
    private var passwordTextField: some View {
        EncameraTextField(L10n.password,
                         type: .secure,
                         text: $viewModel.password1,
                         accessibilityIdentifier: "password"
        )
        .focused($isInputFieldFocused)
        .limitInputLength(to: 100)
        .submitLabel(.done)
        .onSubmit {
            if viewModel.password1.count >= PasswordValidation.minPasswordLength {
                viewModel.enteredPassword = viewModel.password1
                path.append(PasswordEntryScreen.confirmPassword)
            }
        }
        .padding([.horizontal], Spacing.pt24.rawValue)
    }
    
    private var confirmPasswordTextField: some View {
        EncameraTextField(L10n.repeatPassword,
                         type: .secure,
                         text: $viewModel.password2,
                         accessibilityIdentifier: "confirmPassword"
        )
        .limitInputLength(to: 100)
        .submitLabel(.done)
        .onSubmit {
            if viewModel.password2.count >= PasswordValidation.minPasswordLength {
                if viewModel.doesPasswordMatch(password: viewModel.password2) {
                    viewModel.passwordError = nil
                    viewModel.validatePasswordAndNotify()
                } else {
                    viewModel.passwordError = L10n.passwordMismatch
                    viewModel.password2 = ""
                    withAnimation {
                        viewModel.attempts += 1
                    }
                }
            }
        }
        .padding([.horizontal], Spacing.pt24.rawValue)
    }
    
    private var passwordEntryContent: some View {
        VStack(alignment: .center) {
            pinKeyImage
            Spacer().frame(height: 32)
            
            Text(L10n.enterPassword)
                .fontType(.pt24, weight: .bold)
            Spacer().frame(height: 12)
            
            Text(L10n.setPasswordSubtitle)
                .fontType(.pt14)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .pad(.pt64, edge: .bottom)
            
            HStack {
                passwordTextField
            }
        }
    }
    
    private var confirmPasswordContent: some View {
        VStack(alignment: .center) {
            pinKeyImage
            Spacer().frame(height: 32)
            
            Text(L10n.repeatPassword)
                .fontType(.pt24, weight: .bold)
            Spacer().frame(height: 12)
            
            Text(L10n.repeatPasswordSubtitle)
                .fontType(.pt14)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .pad(.pt64, edge: .bottom)
            
            HStack {
                confirmPasswordTextField
            }
            
            if let passwordError = viewModel.passwordError {
                Text(passwordError).alertText()
                    .modifier(Shake(animatableData: CGFloat(viewModel.attempts)))
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            NewOnboardingView(viewModel:
                    .init(
                        screen: .enterPassword,
                        showTopBar: false,
                        content: { _ in
                            AnyView(passwordEntryContent)
                        }))
            .navigationDestination(for: PasswordEntryScreen.self) { screen in
                if screen == .confirmPassword {
                    NewOnboardingView(viewModel:
                            .init(
                                screen: .confirmPassword,
                                showTopBar: false,
                                content: { _ in
                                    AnyView(confirmPasswordContent)
                                })
                    )
                }
            }
        }
        .alert(isPresented: $viewModel.showSuccessAlert) {
            Alert(
                title: Text(L10n.passwordSetSuccessfully),
                message: Text(L10n.passwordSetSuccessMessage),
                dismissButton: .default(Text(L10n.ok)) {
                    presentationMode.wrappedValue.dismiss()
                    viewModel.completedAction?()
                }
            )
        }
        .overlay(alignment: .topLeading) {
            DismissButton {
                presentationMode.wrappedValue.dismiss()
            }.padding(20)
        }
    }
}

#Preview("Password Entry - Initial") {
    PasswordEntry(viewModel: .init(
        keyManager: DemoKeyManager(),
        stateUpdate: { _ in }
    ))
}
