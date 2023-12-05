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

class PasswordEntryViewModel: ObservableObject {
    typealias PasswordStateUpdate = (PasswordEntryState) -> Void
    @Published var password: String = ""
    var passwordBinding: Binding<String>?
    var placeholderText = L10n.password
    var keyManager: KeyManager
    var stateUpdate: PasswordStateUpdate
    @Published var attempts: Int = 0
    @Published var offset: CGSize = .zero
    @Published var passwordState: PasswordEntryState 
    private var cancellables = Set<AnyCancellable>()

    init(placeholderText: String = L10n.password, keyManager: KeyManager, passwordBinding: Binding<String>? = nil, stateUpdate: @escaping (PasswordEntryState) -> Void) {
        self.passwordBinding = passwordBinding
        self.placeholderText = placeholderText
        self.stateUpdate = stateUpdate
        self.keyManager = keyManager
        self.passwordState = .empty
        
        $password.receive(on: RunLoop.main).sink { pass in
            passwordBinding?.wrappedValue = pass
        }.store(in: &cancellables)
        
        
    }
    
    func validatePassword() {
        do {
            let _ = try keyManager.checkPassword(password)
            passwordState = .valid(password)
        } catch let keyManagerError as KeyManagerError {
            if case .invalidPassword = keyManagerError {
                passwordState = .invalid
            }
        } catch {
            print("error")
        }
        stateUpdate(passwordState)
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

    var body: some View {
        VStack {
            ZStack(alignment: .trailing) {
                EncameraTextField(viewModel.placeholderText,
                                  type: .secure,
                                  text: $viewModel.password,
                                  accessibilityIdentifier: "password"
                )
                    .onSubmit(viewModel.validatePassword)
            }
            if case .invalid = viewModel.passwordState {
                Text(L10n.invalidPassword)
                    .alertText()
                    .offset(viewModel.offset)
                    .animation(.spring(), value: viewModel.offset)
                    .modifier(Shake(animatableData: CGFloat(viewModel.attempts)))
                    .onReceive(viewModel.$passwordState) { state in
                        withAnimation {
                            viewModel.attempts += 1
                        }
                    }
                    
            }
        }
    }

    
}
