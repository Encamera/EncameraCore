//
//  KeyPhraseView.swift
//  Encamera
//
//  Created by Alexander Freas on 11.02.24.
//

import SwiftUI
import EncameraCore

class KeyPhraseViewModel: ObservableObject {

    var keyManager: KeyManager

    var phraseArray: [String]? {
        try? keyManager.retrieveKeyPassphrase()
    }

    init(keyManager: KeyManager) {
        self.keyManager = keyManager

    }

}

struct KeyPhraseView: View {

    @StateObject var viewModel: KeyPhraseViewModel
    @State var copyPressed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.yourRecoveryPhrase)
                .frame(maxWidth: .infinity)
                .fontType(.pt24, weight: .bold)
            Text(L10n.copyPhraseInstructions)
            if let phraseArray = viewModel.phraseArray {
                KeyPhraseComponent(words: phraseArray)
                Button(copyPressed ? L10n.recoveryPhraseCopied : L10n.copyPhrase) {
                    let phraseString = phraseArray.joined(separator: " ")

                    UIPasteboard.general.string = phraseString
                    copyPressed = true
                }.textButton()
            }
            Spacer()
        }
        .onChange(of: copyPressed, { oldValue, newValue in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation {
                    copyPressed = false
                }
            }
        })
        .pad(.pt16)
        .gradientBackground()
    }
}

#Preview {
    KeyPhraseView(viewModel: .init(keyManager: DemoKeyManager()))
}
