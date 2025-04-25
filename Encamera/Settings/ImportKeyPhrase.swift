//
//  ImportKeyPhrase.swift
//  Encamera
//
//  Created by Alexander Freas on 11.02.24.
//

import SwiftUI
import EncameraCore

enum ImportKeyPhraseError: Error {
    case invalidKeyPhrase(String)
    case couldNotImportKeyPhrase
}

@MainActor
class ImportKeyPhraseViewModel: ObservableObject {

    var keyManager: KeyManager

    @Published var importError: ImportKeyPhraseError?
    @Published var enteredKeyPhrase: String = "" {
        didSet {
            let components: [String] = enteredKeyPhrase.components(separatedBy: " ").filter({$0.isEmpty == false})
            words = components
        }
    }
    @Published var words: [String] = []
    @Published var showWarningForOverwrite: Bool = false

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    func importKeyPhrase() throws {
        do {
            try keyManager.generateKeyFromPasswordComponentsAndSave(words, name: AppConstants.defaultKeyName)
        } catch let error as KeyManagerError {
            importError = .invalidKeyPhrase(error.displayDescription)
            print("Error importing key phrase: \(error)")
            throw error
        } catch {
            importError = .couldNotImportKeyPhrase
            throw error
        }
    }
}

struct ImportKeyPhrase: View {

    @StateObject var viewModel: ImportKeyPhraseViewModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(alignment: .leading) {
            Text(L10n.enterKeyPhraseDescription)
                .fontType(.pt14)
            KeyPhraseComponent(words: viewModel.words)
            TextField(L10n.enterKeyPhrase, text: $viewModel.enteredKeyPhrase)
                .padding()
                .border(Color.gray)
                .padding()
                .noAutoModification()
            if let error = viewModel.importError {
                if case .invalidKeyPhrase(let message) = error {
                    Text("\(L10n.errorImportingKeyPhrase): \(message)").alertText()
                } else {
                    Text(L10n.errorImportingKeyPhrase).alertText()
                }
            }
            Spacer()
            Button(L10n.import, action: {
                viewModel.showWarningForOverwrite = true
            }).primaryButton()
        }
        .pad(.pt16)
        .alert(isPresented: $viewModel.showWarningForOverwrite) {
            Alert(title: Text(L10n.overwriteKeyPhrase), message: Text(L10n.overwriteAreYouSure), primaryButton: .destructive(Text(L10n.imSure), action: {
                do {
                    try viewModel.importKeyPhrase()
                    EventTracking.trackKeyPhraseBackupImported()
                    presentationMode.wrappedValue.dismiss()
                } catch {

                }
            }), secondaryButton: .cancel())
        }
        .onAppear {
            EventTracking.trackImportKeyPhraseScreenOpened()
        }
        .navigationTitle(L10n.importKeyPhrase)
        .gradientBackground()
    }
}

#Preview {
    NavigationStack {
        ImportKeyPhrase(viewModel: .init(keyManager: DemoKeyManager()))
    }
}
