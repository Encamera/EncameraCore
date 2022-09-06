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
    @Published var isShowingAddKeyView: Bool = false
    private var cancellables = Set<AnyCancellable>()
    
    
    init(keyManager: KeyManager) {
        self.keyManager = keyManager
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
        let binding = Binding<Bool> {
            viewModel.isShowingAddKeyView
        } set: { newValue in
            viewModel.isShowingAddKeyView = newValue
        }

        List {
            Section {
                NavigationLink(isActive: binding) {
                    KeyGeneration(viewModel: .init(keyManager: viewModel.keyManager), shouldBeActive: binding)
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
            }
            Section(header: Text("Keys").foregroundColor(.white)) {
                
                if let activeKey = viewModel.activeKey {
                    keyCell(key: activeKey, isActive: true)
                }
                
                ForEach(viewModel.keys.filter({$0 != viewModel.activeKey}), id: \.name) { key in
                    keyCell(key: key, isActive: false)
                }
            }
        }.listStyle(InsetGroupedListStyle())
        .screenBlocked()
        .onAppear {
            viewModel.loadKeys()
        }.navigationTitle("Key Management")
        
    }
    
    func keyCell(key: PrivateKey, isActive: Bool) -> some View {
        NavigationLink {
            KeyDetailView(viewModel: .init(keyManager: viewModel.keyManager, key: key))
        } label: {
            HStack {
                HStack {
                    VStack(alignment: .leading) {
                        Text(key.name)
                            .font(.title)
                        Text(DateUtils.dateOnlyString(from: key.creationDate))
                            .font(.caption)
                    }
                    Spacer()
                }.padding()
                if key == viewModel.activeKey {
                    HStack {
                        Text("Active")
                        Image(systemName: "key.fill")
                    }.foregroundColor(.green)
                    
                } else {
                    Image(systemName: "key")
                }
            }
        }
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
