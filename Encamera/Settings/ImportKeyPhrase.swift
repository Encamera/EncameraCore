//
//  ImportKeyPhrase.swift
//  Encamera
//
//  Created by Alexander Freas on 11.02.24.
//

import SwiftUI
import EncameraCore

class ImportKeyPhraseViewModel: ObservableObject {

    var keyManager: KeyManager

    @Published var enteredKeyPhrase: String = "" {
        didSet {
            print("words: \(words)")
            let components: [String] = enteredKeyPhrase.components(separatedBy: " ").filter({$0.isEmpty == false})
            words = components
        }
    }
    @Published var words: [String] = []
    @Published var showWarningForOverwrite: Bool = false

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    func importKeyPhrase() {
        do {
            try keyManager.generateKeyFromPasswordComponents(words, name: AppConstants.defaultKeyName)
        } catch {
            print("Error importing key phrase: \(error)")
        }
    }
}

struct ImportKeyPhrase: View {

    @StateObject var viewModel: ImportKeyPhraseViewModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Import Key Phrase")
                .fontType(.pt16, weight: .bold)
            Text("Enter the key phrase you want to import. Separate each word with a space.\nThis will overwrite your current key phrase.")
                .fontType(.pt14)
            KeyPhraseComponent(words: viewModel.words)
            TextField("Enter Key Phrase", text: $viewModel.enteredKeyPhrase)
                .padding()
                .border(Color.gray)
                .padding()
                .noAutoModification()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Import", action: {
                    viewModel.showWarningForOverwrite = true
                })
                    .textButton()
            }
        }
        .alert(isPresented: $viewModel.showWarningForOverwrite) {
            Alert(title: Text("Overwrite Key Phrase?"), message: Text("Are you sure you want to overwrite your current key phrase?"), primaryButton: .default(Text("Yes"), action: {
                viewModel.importKeyPhrase()
            }), secondaryButton: .cancel())
        }

    }
}

#Preview {
    NavigationStack {
        ImportKeyPhrase(viewModel: .init(keyManager: DemoKeyManager()))
    }
}
