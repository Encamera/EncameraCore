//
//  KeySelectionList.swift
//  Encamera
//
//  Created by Alexander Freas on 22.06.22.
//

import SwiftUI
import Combine

enum KeySelectionError: Error {
    case loadKeysError
}

class KeySelectionListViewModel: ObservableObject {
    var keyManager: KeyManager
    @Published var keys: [PrivateKey] = []
    @Published var selectionError: KeySelectionError?
    @Published var activeKey: PrivateKey?
    private var cancellables = Set<AnyCancellable>()
    
    
    init(keyManager: KeyManager) {
        self.keyManager = keyManager
        keyManager.keyPublisher.sink { key in
            self.activeKey = key
        }.store(in: &cancellables)
    }
    
    func loadKeys() {
        do {
            keys = try keyManager.storedKeys()
            activeKey = keyManager.currentKey
            selectionError = nil
        } catch {
            selectionError = .loadKeysError
        }
    }
}

struct KeySelectionList: View {
    
    @State var presentingAddKeySheet: Bool = false
    @State var isShowingAddKeyView: Bool = false
    
    @StateObject var viewModel: KeySelectionListViewModel
    
    var body: some View {
        
        List {
            NavigationLink(isActive: $isShowingAddKeyView) {
                KeyGeneration(viewModel: .init(keyManager: viewModel.keyManager), shouldBeActive: $isShowingAddKeyView)
            } label: {
                KeyOperationCell(title: "Create New Key", imageName: "plus.app.fill")
            }
            NavigationLink {
                KeyEntry(viewModel: .init(keyManager: viewModel.keyManager, isShowing: .constant(true)))
                
            } label: {
                KeyOperationCell(title: "Add Existing Key", imageName: "lock.doc.fill")
            }
            KeyOperationCell(title: "Backup Keys", imageName: "doc.on.doc.fill").onTapGesture {
                guard let doc = try? viewModel.keyManager.createBackupDocument() else {
                    return
                }
                let pasteboard = UIPasteboard.general
                pasteboard.string = doc
            }
            ForEach(viewModel.keys, id: \.name) { key in
                NavigationLink {
                    KeyPickerView(viewModel: .init(keyManager: viewModel.keyManager, key: key))
                } label: {
                    KeySelectionCell(viewModel: .init(key: key, isActive: key == viewModel.activeKey))
                }
            }
        }
        .screenBlocked()
        .onAppear {
            viewModel.loadKeys()
        }.navigationTitle("Key Selection")
        
    }
}

struct KeySelectionList_Previews: PreviewProvider {
    
    static var keyManager: DemoKeyManager = {
        let manager = DemoKeyManager()
        manager.storedKeysValue = [
            PrivateKey(name: "first key", keyBytes: [], creationDate: Date()),
            PrivateKey(name: "second key", keyBytes: [], creationDate: Date()),
            PrivateKey(name: "third key", keyBytes: [], creationDate: Date()),
        ]
        return manager
    }()
    
    static var previews: some View {
        KeySelectionList(viewModel: .init(keyManager: keyManager))
    }
}
