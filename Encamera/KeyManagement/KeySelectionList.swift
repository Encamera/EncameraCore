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
    
    struct KeyItemModel: Identifiable {
        let key: PrivateKey
        let imageCount: Int
        var id: String {
            key.name
        }
    }
    
    var keyManager: KeyManager
    @Published var keys: [KeyItemModel] = []
    @Published var selectionError: KeySelectionError?
    @Published var activeKey: KeyItemModel?
    @Published var isShowingAddKeyView: Bool = false
    private var cancellables = Set<AnyCancellable>()
    
    
    init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }
    
    func loadKeys() {
        do {
            let storage = DataStorageUserDefaultsSetting()
            keys = try keyManager.storedKeys().map { key in
                let model = storage.storageModelFor(keyName: key.name)
                let count = model?.countOfFiles() ?? 0
                return KeyItemModel(key: key, imageCount: count)
            }
            if let currentKey = keyManager.currentKey {
                activeKey = keys.first(where: {$0.key == currentKey})
            }
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
                    KeyEntry(viewModel: .init(keyManager: viewModel.keyManager))
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
                    keyCell(model: activeKey, isActive: true)
                }
                
                ForEach(viewModel.keys.filter({$0.key != viewModel.activeKey?.key})) { key in
                    keyCell(model: key, isActive: false)
                }
            }
        }.listStyle(InsetGroupedListStyle())
        .screenBlocked()
        .onAppear {
            viewModel.loadKeys()
        }.navigationTitle("Key Management")
        
    }
    
    func keyCell(model: KeySelectionListViewModel.KeyItemModel, isActive: Bool) -> some View {
        let key = model.key
        return NavigationLink {
            KeyDetailView(viewModel: .init(keyManager: viewModel.keyManager, key: key))
        } label: {
            HStack {
                HStack {
                    Text("\(model.imageCount)")
                        .font(.caption)
                        .frame(width: 30)
                    VStack(alignment: .leading) {
                        Text(key.name)
                            .font(.title)
                        Text(DateUtils.dateOnlyString(from: key.creationDate))
                            .font(.caption)
                    }
                    Spacer()
                }.padding()
                if isActive {
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
