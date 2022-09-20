//
//  PasswordEntry.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import SwiftUI

enum PasswordEntryState: Equatable {
    case empty
    case invalid
    case valid(String)
}

class PasswordEntryViewModel: ObservableObject {
    typealias PasswordStateUpdate = (PasswordEntryState) -> Void
    @Published var password: String = ""
    var placeholderText = "Password"
    var keyManager: KeyManager
    var stateUpdate: PasswordStateUpdate
    @Published var attempts: Int = 0
    @Published var offset: CGSize = .zero
    @Published var passwordState: PasswordEntryState 

    init(placeholderText: String = "Password", keyManager: KeyManager, stateUpdate: @escaping (PasswordEntryState) -> Void) {
        self.placeholderText = placeholderText
        self.stateUpdate = stateUpdate
        self.keyManager = keyManager
        self.passwordState = .empty
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
                EncameraTextField(viewModel.placeholderText, type: .secure, text: $viewModel.password)
                    .onSubmit(viewModel.validatePassword)
                    .cornerRadius(25)
                Button(action: viewModel.validatePassword) {
                    Image(systemName: "lock.circle")
                        .resizable()
                        .frame(width: 50.0, height: 50.0)
                        .foregroundColor(.white)
                }
                
            }
            let _ = print("passwordState", viewModel.passwordState)
            if case .invalid = viewModel.passwordState {
                Text("Invalid Password")
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

//struct PasswordEntry_Previews: PreviewProvider {
//    static var previews: some View {
//        
//        PasswordEntry(viewModel: .init(state: .constant(.invalid), keyManager: DemoKeyManager()))
//    }
//}
