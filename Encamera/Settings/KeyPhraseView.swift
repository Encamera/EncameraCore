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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Recovery Phrase")
                .frame(maxWidth: .infinity)
                .fontType(.pt24, weight: .bold)
            Text("Write down or copy these words in the right order and save them somewhere safe")
            if let phraseArray = viewModel.phraseArray {
                KeyPhraseComponent(words: phraseArray)
                Button("Copy Phrase") {
                    let phraseString = phraseArray.joined(separator: " ")

                    // copy to clipboard
                    UIPasteboard.general.string = phraseString
                }.textButton()
            }

            Spacer()

        }
    }
}

#Preview {
    KeyPhraseView(viewModel: .init(keyManager: DemoKeyManager()))
}
