//
//  PromptToErase.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import SwiftUI

class PromptToEraseViewModel: ObservableObject {
    @Published var eraseButtonPressed = false
    @Published var error: KeyManagerError?
    @Published var passwordState: PasswordEntryState = .empty
    var eraserUtil: EraserUtils
    var keyManager: KeyManager
    var scope: ErasureScope
    
    init(scope: ErasureScope, keyManager: KeyManager, fileAccess: FileAccess) {
        self.eraserUtil = EraserUtils(keyManager: keyManager, fileAccess: fileAccess, erasureScope: scope)
        self.keyManager = keyManager
        self.scope = scope
    }
    
    func performErase() {
        Task {
            do {
                guard case .valid(let string) = passwordState else {
                    return
                }

                if try keyManager.checkPassword(string) == true {
                    try await eraserUtil.erase()
                    exit(0)
                }
                
            } catch let keyManagerError as KeyManagerError {
                await MainActor.run {
                    self.error = keyManagerError
                }
            } catch {
                print("Error", error)
            }
        }
    }
    
    
}

struct PromptToErase: View {
    
    @StateObject var viewModel: PromptToEraseViewModel

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                Text(viewModel.scope.explanationString)
                if case .valid = viewModel.passwordState {
                    Button("I'm sure, erase now") {
                        viewModel.performErase()
                    }.primaryButton()
                } else {
                    PasswordEntry(viewModel: .init(keyManager: viewModel.keyManager, stateUpdate: { update in
                        viewModel.passwordState = update
                    }))
                }
                    
                
                Spacer()
                
                
            }.padding()
                .navigationTitle("Erase app data")
        }
        
        
    }
    
    
}


extension ErasureScope {
    
    var explanationString: LocalizedStringKey {
        switch self {
        case .appData:
            return appDataExplanation
        case .allData:
            return allDataExplanation
        }
    }
    
    private var allDataExplanation: LocalizedStringKey {
                """
                Are you sure you want to erase __all__ app data?

                __This will erase:__

                • All your stored keys 🔑
                • Your password 🔐
                • App settings 🎛
                • Media you have stored locally or on iCloud 💾

                You can create a backup of your keys from the key management screen.
                
                The app will quit after erase is finished.

                """

    }
    
    private var appDataExplanation: LocalizedStringKey {
        """
        Are you sure you want to erase all app data?

        __This will erase:__

        • All your stored keys 🔑
        • Your password 🔐
        • App settings 🎛

        __This will not erase:__

        • Media you have stored locally or on iCloud 💾

        You can create a backup of your keys from the key management screen.
        
        The app will quit after erase is finished.

        """
    }
}

struct PromptToErase_Previews: PreviewProvider {
    static var manager: KeyManager {
        let manager = DemoKeyManager()
        manager.password = "pass"
        return manager
    }
    static var previews: some View {
        Text("hi.").sheet(isPresented: .constant(true)) {
            PromptToErase(viewModel: .init(scope: .allData, keyManager: manager, fileAccess: DemoFileEnumerator()))
        }
        
    }
}
