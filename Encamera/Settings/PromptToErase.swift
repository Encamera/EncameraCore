//
//  PromptToErase.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import SwiftUI

class PromptToEraseViewModel: ObservableObject {
    @Published var eraseButtonPressed = false
    @Published var password: String = ""
    @Published var error: KeyManagerError?
    var eraserUtil: EraserUtils
    var keyManager: KeyManager
    var scope: ErasureScope
    
    init(scope: ErasureScope, keyManager: KeyManager, fileAccess: FileAccess) {
        self.eraserUtil = EraserUtils(keyManager: keyManager, fileAccess: fileAccess, erasureScope: scope)
        self.keyManager = keyManager
        self.scope = scope
    }
    
    
    func validatePassword() {
        Task {
            do {
                if try keyManager.checkPassword(password) == true {
                    try await eraserUtil.erase()
                }
                
            } catch let keyManagerError as KeyManagerError {
                self.error = keyManagerError
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
            VStack {
                Text(viewModel.scope.explanationString)
                Spacer()
                Button("I'm sure, erase") {
                    
                }.primaryButton()
            }
            .navigationTitle("Erase app data")
        }
        
        
    }
    
    
}

struct PromptToErase_Previews: PreviewProvider {
    static var previews: some View {
        Text("hi.").sheet(isPresented: .constant(true)) {
            PromptToErase(viewModel: .init(scope: .allData, keyManager: DemoKeyManager(), fileAccess: DemoFileEnumerator()))
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
                Are you sure you want to erase all app data?

                __This will erase:__

                • All your stored keys 🔑
                • Your password 🔐
                • App settings 🎛
                • Media you have stored locally or on iCloud 💾

                If you need to, you can create a backup of your keys from the key management screen.

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

        If you need to, you can create a backup of your keys from the key management screen.

        """
    }
}
