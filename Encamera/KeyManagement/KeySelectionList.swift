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
    var purchaseManager: PurchasedPermissionManaging
    @MainActor
    @Published var keys: [KeyItemModel] = []
    @Published var selectionError: KeySelectionError?
    @Published var activeKey: KeyItemModel?
    @Published var isShowingAddKeyView: Bool = false
    @Published var isShowingAddExistingKeyView: Bool = false
    private var cancellables = Set<AnyCancellable>()
    
    
    init(keyManager: KeyManager, purchaseManager: PurchasedPermissionManaging) {
        self.keyManager = keyManager
        self.purchaseManager = purchaseManager

        keyManager.keyPublisher.receive(on: DispatchQueue.main).sink { _ in
            Task {
                await self.loadKeys()
            }
        }.store(in: &cancellables)
    }
    
    @MainActor func loadKeys() {
        do {
            let storage = DataStorageUserDefaultsSetting()
            keys = try keyManager.storedKeys().map { key in
                let model = storage.storageModelFor(keyName: key.name)
                let count = model?.countOfFiles(matchingFileExtension: [
                    MediaType.photo.fileExtension,
                ]) ?? 0
                return KeyItemModel(key: key, imageCount: count)
            }
            if let currentKey = keyManager.currentKey {
                activeKey = keys.first(where: {$0.key == currentKey})
            } else {
                activeKey = nil
            }
            selectionError = nil
        } catch {
            selectionError = .loadKeysError
        }
    }
    
    @MainActor
    var shouldShowPurchaseScreenForKeys: Bool {
        
        if self.keys.count == 0 {
            return false
        }
        
        return purchaseManager.isAllowedAccess(feature: .createKey(count: .infinity)) == false
    }

}

struct KeySelectionList: View {
    
    @State var presentingAddKeySheet: Bool = false
    
    @StateObject var viewModel: KeySelectionListViewModel
    
    
    var body: some View {

        List {
            Section {
                let createNewKeyActive = Binding<Bool> {
                    viewModel.isShowingAddKeyView
                } set: { newValue in
                    viewModel.isShowingAddKeyView = newValue
                }
                NavigationLink(isActive: createNewKeyActive) {
                    if viewModel.shouldShowPurchaseScreenForKeys {
                        ProductStoreView(showDismissButton: false)
                    } else {
                        KeyGeneration(viewModel: .init(keyManager: viewModel.keyManager), shouldBeActive: createNewKeyActive)
                    }
                } label: {
                    KeyOperationCell(title: "Create New Key", imageName: "plus.app.fill")
                }
                let addExistingKeyActive = Binding<Bool> {
                    viewModel.isShowingAddExistingKeyView
                } set: { newValue in
                    viewModel.isShowingAddExistingKeyView = newValue
                }
                NavigationLink(isActive: addExistingKeyActive) {
                    if viewModel.shouldShowPurchaseScreenForKeys {
                        ProductStoreView(showDismissButton: false
                        )
                    } else {
                        KeyEntry(viewModel: .init(keyManager: viewModel.keyManager, dismiss: addExistingKeyActive))
                    }
                } label: {
                    KeyOperationCell(title: "Add Existing Key", imageName: "lock.doc.fill")
                }
                //                KeyOperationCell(title: "Backup Keys", imageName: "doc.on.doc.fill").onTapGesture {
                //                    guard let doc = try? viewModel.keyManager.createBackupDocument() else {
                //                        return
                //                    }
                //                    let pasteboard = UIPasteboard.general
                //                    pasteboard.string = doc
                //                }
            }.listRowBackground(Color.foregroundSecondary)
            if viewModel.keys.count > 0 {
                Section(header: Text("Keys")
                    .fontType(.small)) {
                        
                        if let activeKey = viewModel.activeKey {
                            keyCell(model: activeKey, isActive: true)
                        }
                        
                        ForEach(viewModel.keys.filter({$0.key != viewModel.activeKey?.key})) { key in
                            keyCell(model: key, isActive: false)
                        }
                    }
                    .listRowBackground(Color.foregroundSecondary)
                    
            }
        }
            
        .listStyle(InsetGroupedListStyle())
        .screenBlocked()
        .scrollContentBackgroundColor(Color.background)
        .onAppear {
            viewModel.loadKeys()
        }
        .navigationTitle("Key Management")
    }
    
    func keyCell(model: KeySelectionListViewModel.KeyItemModel, isActive: Bool) -> some View {
        let key = model.key
        return NavigationLink {
            KeyDetailView(viewModel: .init(keyManager: viewModel.keyManager, key: key))
        } label: {
            HStack {
                HStack {
                    Text("\(model.imageCount)")
                        .fontType(.small)
                        .frame(width: 30)
                    VStack(alignment: .leading) {
                        Text(key.name)
                            .fontType(.medium)
                        if isActive {
                            Text("Active")
                                .foregroundColor(.activeKey)
                                .fontType(.small)
                        }
                        Text(DateUtils.dateOnlyString(from: key.creationDate))
                            .fontType(.small)
                    }
                    Spacer()
                }.padding()
                if isActive {
                    HStack {
                        Image(systemName: "key.fill")
                    }
                    .foregroundColor(.activeKey)
                    
                } else {
                    Image(systemName: "key")
                }
            }.fontType(.small)
                
        }
    }
}

struct KeySelectionList_Previews: PreviewProvider {
    
    static var keyManager: DemoKeyManager = {
        let manager = DemoKeyManager()
        let key = PrivateKey(name: "DefaultKey", keyBytes: [], creationDate: Date())
        manager.storedKeysValue = [
            key,
            PrivateKey(name: "second key", keyBytes: [], creationDate: Date()),
            PrivateKey(name: "third key", keyBytes: [], creationDate: Date()),
        ]
        manager.currentKey = key
        return manager
    }()
    
    static var previews: some View {
        KeySelectionList(viewModel: .init(keyManager: keyManager, purchaseManager: AppPurchasedPermissionUtils()))
            .preferredColorScheme(.dark)
            .previewDevice("iPhone 8")
    }
}
