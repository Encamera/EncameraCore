//
//  KeySelectionList.swift
//  Shadowpix
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
    @Published var keys: [ImageKey] = []
    @Published var selectionError: KeySelectionError?
    @Published var activeKey: ImageKey?
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
    @ObservedObject var viewModel: KeySelectionListViewModel
    
    var body: some View {
        
        NavigationView {
            List {
                NavigationLink {
                    KeyGeneration(viewModel: .init(keyManager: viewModel.keyManager))
                } label: {
                    AddKeyCell(title: "Create New Key")
                }
                NavigationLink {
                    KeyEntry(viewModel: .init(keyManager: viewModel.keyManager, isShowing: .constant(true)))

                } label: {
                    AddKeyCell(title: "Add Key")
                }
                ForEach(viewModel.keys, id: \.name) { key in
                    NavigationLink {
                        KeyPickerView(viewModel: .init(keyManager: viewModel.keyManager, key: key))
                    } label: {
                        KeySelectionCell(viewModel: .init(key: key, isActive: key == viewModel.activeKey))
                    }
                }
            }
            .onAppear {
                viewModel.loadKeys()
            }.navigationTitle("Key Selection")
        }
    }
}

struct KeySelectionList_Previews: PreviewProvider {
    
    static var keyManager: DemoKeyManager = {
        let manager = DemoKeyManager()
        manager.storedKeysValue = [
            ImageKey(name: "first key", keyBytes: [], creationDate: Date()),
            ImageKey(name: "second key", keyBytes: [], creationDate: Date()),
            ImageKey(name: "third key", keyBytes: [], creationDate: Date()),
        ]
        return manager
    }()
    
    static var previews: some View {
        KeySelectionList(viewModel: .init(keyManager: keyManager))
    }
}
