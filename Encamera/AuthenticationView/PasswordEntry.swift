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
    private var cancellables = Set<AnyCancellable>()

    init(placeholderText: String = L10n.password, 
         confirmPlaceholderText: String = L10n.repeatPassword,
         keyManager: KeyManager,
         stateUpdate: @escaping (PasswordEntryState) -> Void) {
        self.placeholderText = placeholderText
        self.confirmPlaceholderText = confirmPlaceholderText
        self.stateUpdate = stateUpdate
        self.keyManager = keyManager
        self.passwordState = .empty
    }
    
    func doesPasswordMatch(password: String) -> Bool {
        return PasswordValidator.validatePasswordPair(password, password2: enteredPassword, type: .password) == .valid
    }
    
    func validatePasswordAndNotify() {
        do {
            let _ = try keyManager.checkPassword(enteredPassword)
            passwordState = .valid(enteredPassword)
            stateUpdate(passwordState)
        } catch {
            passwordState = .invalid
            stateUpdate(passwordState)
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

    var body: some View {
        NavigationStack(path: $path) {
            NewOnboardingView(viewModel:
                    .init(
                        screen: .enterPassword,
                        showTopBar: false,
                        content: { _ in
                            AnyView(
                                VStack(alignment: .center) {
                                    ZStack {
                                        Image(systemName: "key.fill")
                                            .font(.system(size: 48))
                                        Rectangle()
                                            .foregroundColor(.clear)
                                            .frame(width: 96, height: 96)
                                            .background(Color.actionYellowGreen.opacity(0.1))
                                            .cornerRadius(24)
                                    }
                                    Spacer().frame(height: 32)

                                    Text(L10n.enterPassword)
                                        .fontType(.pt24, weight: .bold)
                                    Spacer().frame(height: 12)

                                    Text(L10n.setPasswordSubtitle)
                                        .fontType(.pt14)
                                        .lineLimit(2, reservesSpace: true)
                                        .multilineTextAlignment(.center)
                                        .pad(.pt64, edge: .bottom)
                                    
                                    EncameraTextField(viewModel.placeholderText,
                                                      type: .secure,
                                                      text: $viewModel.password1,
                                                      accessibilityIdentifier: "password"
                                    )
                                }.frame(width: 290)
                            )
                        }))
            .onChange(of: viewModel.password1) { oldValue, newValue in
                if !newValue.isEmpty && newValue.count >= PasswordValidation.minPasswordLength {
                    viewModel.enteredPassword = newValue
                    path.append(PasswordEntryScreen.confirmPassword)
                }
            }
            .navigationDestination(for: PasswordEntryScreen.self) { screen in
                if screen == .confirmPassword {
                    NewOnboardingView(viewModel:
                            .init(
                                screen: .confirmPassword,
                                showTopBar: false,
                                content: { _ in
                                    AnyView(
                                        VStack(alignment: .center) {
                                            ZStack {
                                                Image(systemName: "key.fill")
                                                    .font(.system(size: 48))
                                                Rectangle()
                                                    .foregroundColor(.clear)
                                                    .frame(width: 96, height: 96)
                                                    .background(Color.actionYellowGreen.opacity(0.1))
                                                    .cornerRadius(24)
                                            }
                                            Spacer().frame(height: 32)
                                            
                                            Text(L10n.repeatPassword)
                                                .fontType(.pt24, weight: .bold)
                                            Spacer().frame(height: 12)
                                            
                                            Text(L10n.repeatPasswordSubtitle)
                                                .fontType(.pt14)
                                                .multilineTextAlignment(.center)
                                                .lineLimit(2, reservesSpace: true)
                                                .pad(.pt64, edge: .bottom)
                                            
                                            EncameraTextField(viewModel.confirmPlaceholderText,
                                                              type: .secure,
                                                              text: $viewModel.password2,
                                                              accessibilityIdentifier: "confirmPassword"
                                            )
                                            
                                            if let passwordError = viewModel.passwordError {
                                                Text(passwordError).alertText()
                                                    .modifier(Shake(animatableData: CGFloat(viewModel.attempts)))
                                            }
                                        }.frame(width: 290)
                                    )
                                })
                    )
                    .onChange(of: viewModel.password2) { oldValue, newValue in
                        if newValue.count >= PasswordValidation.minPasswordLength {
                            if viewModel.doesPasswordMatch(password: newValue) {
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
                }
            }
        }
    }
}

#Preview("Password Entry - Initial") {
    PasswordEntry(viewModel: .init(
        keyManager: DemoKeyManager(),
        stateUpdate: { _ in }
    ))
}

//#Preview("Password Entry - Confirmation") {
//    let viewModel = PasswordEntryViewModel(
//        keyManager: DemoKeyManager(),
//        stateUpdate: { _ in }
//    )
//    viewModel.password1 = "test123"
//    PasswordEntry(viewModel: viewModel)
//}
//
//#Preview("Password Entry - Error") {
//    let viewModel = PasswordEntryViewModel(
//        keyManager: DemoKeyManager(),
//        stateUpdate: { _ in }
//    )
//    viewModel.password1 = "test123"
//    viewModel.password2 = "test456"
//    viewModel.passwordError = L10n.passwordMismatch
//    viewModel.attempts = 1
//    PasswordEntry(viewModel: viewModel)
//}
