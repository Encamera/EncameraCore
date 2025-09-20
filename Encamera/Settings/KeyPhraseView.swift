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
    @Published var useiCloudKeyBackup: Bool = false

    var phraseArray: KeyPassphrase?

    private var cancellables = Set<AnyCancellable>()

    init(keyManager: KeyManager) {
        self.keyManager = keyManager
        phraseArray = try? keyManager.retrieveKeyPassphrase()
        self.useiCloudKeyBackup = keyManager.isSyncEnabled
        setupToggleObserver()
    }

    func toggleCloudBackup(isOn: Bool) {
        do {
            try self.keyManager.backupKeychainToiCloud(backupEnabled: isOn)
        } catch {
            debugPrint("Error toggling key backup to iCloud: \(error)")
        }
    }

    func setupToggleObserver() {
        self.$useiCloudKeyBackup.dropFirst().sink { [weak self] value in
            guard let self else { return }
            try? self.keyManager.backupKeychainToiCloud(backupEnabled: value)
        }.store(in: &cancellables)
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
            
            Divider()
                .padding(.vertical, 16)
            
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $viewModel.useiCloudKeyBackup) {
                    Text(L10n.Settings.backupKeyToiCloud)
                        .fontType(.pt14, weight: .bold)
                }
                .tint(Color.actionYellowGreen)
                
                Text(L10n.Settings.backupKeyToiCloudDescription)
                    .fontType(.pt12)
                    .foregroundColor(.secondary)
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
        .onAppear {
            EventTracking.trackKeyPhraseBackupScreenOpened()
        }
        .pad(.pt16)
        .gradientBackground()
    }
}

#Preview {
    KeyPhraseView(viewModel: .init(keyManager: DemoKeyManager()))
}
