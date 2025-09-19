//
//  KeyPhraseView.swift
//  Encamera
//
//  Created by Alexander Freas on 11.02.24.
//

import SwiftUI
import EncameraCore
import Combine

class KeyPhraseViewModel: ObservableObject {

    var keyManager: KeyManager

    var phraseArray: KeyPassphrase?

    private var cancellables = Set<AnyCancellable>()

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
        phraseArray = try? keyManager.retrieveKeyPassphrase()
    }

    func toggleCloudBackup(isOn: Bool) {
        do {
            try self.keyManager.backupKeychainToiCloud(backupEnabled: isOn)
        } catch {
            debugPrint("Error toggling key backup to iCloud: \(error)")
        }
    }

}

struct KeyPhraseView: View {

    @StateObject var viewModel: KeyPhraseViewModel
    @State var copyPressed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.copyPhraseInstructions)
            if let passphrase = viewModel.phraseArray {
                let phraseArray = passphrase.words
                KeyPhraseComponent(words: phraseArray)
                Spacer()
                HStack {
                    Spacer()
                    Button(copyPressed ? L10n.recoveryPhraseCopied : L10n.copyPhrase) {
                        let phraseString = phraseArray.joined(separator: " ")
                        EventTracking.trackKeyPhraseBackupCopied()
                        UIPasteboard.general.string = phraseString
                        copyPressed = true
                    }.primaryButton()
                    Spacer()
                }
            }
//            Divider()
//            Toggle("Back up key to iCloud", isOn: $viewModel.iCloudBackupEnabled)
//            Text("If enabled, your key will automatically be backed up to your iCloud Keychain. If you lose your device, you will still have access to files stored on iCloud if you choose this option.")
//                .fontType(.pt12)
//            Spacer()
        }
        .onChange(of: copyPressed, { oldValue, newValue in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation {
                    copyPressed = false
                }
            }
        })
        .onAppear {
            EventTracking.trackKeyPhraseBackupScreenOpened()
        }
        .navigationTitle(L10n.yourRecoveryPhrase)
        .pad(.pt16)
        .gradientBackground()
    }
}

#Preview {
    KeyPhraseView(viewModel: .init(keyManager: DemoKeyManager()))
}
