//
//  KeySelectionGridItem.swift
//  Encamera
//
//  Created by Alexander Freas on 28.11.22.
//

import SwiftUI
import Combine
import EncameraCore

actor KeyInfoFetcher {
    
}
class KeySelectionGridItemModel: ObservableObject {
    
    var fileReader: FileReader = DiskFileAccess()
    var storageModel: DataStorageModel?
    var storageType: StorageType? {
        storageModel?.storageType
    }
    
    @Published var countOfMedia: Int = 0

    init(key: PrivateKey) {
        Task {
            await fileReader.configure(
                with: key,
                storageSettingsManager: DataStorageUserDefaultsSetting()
            )
            
        }
        storageModel = DataStorageUserDefaultsSetting().storageModelFor(keyName: key.name)
        self.countOfMedia = storageModel?.countOfFiles(matchingFileExtension: [MediaType.photo.fileExtension, MediaType.video.fileExtension]) ?? 0

    }
}
struct KeySelectionGridItem: View {
    
    @ObservedObject var viewModel: KeySelectionGridItemModel
    @State var imageCount: Int?
    @State var leadingImage: UIImage?
    var keyName: String
    var isActiveKey: Bool = false

    init(key: PrivateKey, isActiveKey: Bool) {
        keyName = key.name
        self.viewModel = KeySelectionGridItemModel(key: key)
        self.isActiveKey = isActiveKey
    }
    
    func load() {
        Task {
            let thumb = try await viewModel.fileReader.loadLeadingThumbnail()
            await MainActor.run {
                self.imageCount = viewModel.countOfMedia
                self.leadingImage = thumb
            }
        }
    }
    
    var body: some View {
            VStack {
                if isActiveKey {
                    Text(L10n.active)
                        .fontType(.extraSmall)
                        .padding(4)
                        .frame(maxWidth: .infinity)
                        .background {
                            Color.green
                        }
                }
                
                HStack {
                    Text(keyName)
                        .fontType(.mediumSmall)
                        .frame(maxWidth: .infinity)
                    
                    Spacer()

                }.padding()
                Spacer()
                HStack {
                    if let imageCount = imageCount {
                        Text("\(imageCount)")
                    }
                    Spacer()

                    if let iconName = viewModel.storageType?.iconName {
                        Image(systemName: iconName)
                            .padding(2)
                    }
                                    }
                .fontType(.small)
                .padding(10)
            }
            .background {
                Group {
                    if let leadingImage = leadingImage {
                        Image(uiImage: leadingImage)
                            .resizable()
                            .aspectRatio(contentMode:.fill)
                    } else {
                        Color.foregroundPrimary
                    }
                }
                .opacity(0.7)
                .blur(radius: 5)
                
            }
            .contentShape(Rectangle())
            .clipped()

        .task {
            load()
        }
        
    }
}

class KeySelectionGridViewModel: ObservableObject {
    @Published var keys: [PrivateKey] = []
    @Published var activeKey: PrivateKey?
    var keyManager: KeyManager
    var fileManager: FileAccess
    @Published var isShowingAddKeyView: Bool = false
    @Published var isShowingAddExistingKeyView: Bool = false
    @Published var isKeyTutorialClosed: Bool = true
    var purchaseManager: PurchasedPermissionManaging

    private var cancellables = Set<AnyCancellable>()

    init(keyManager: KeyManager, purchaseManager: PurchasedPermissionManaging, fileManager: FileAccess) {
        self.purchaseManager = purchaseManager
        self.fileManager = fileManager
        self.keyManager = keyManager
            keyManager.keyPublisher.receive(on: DispatchQueue.main).sink { key in
            self.loadKeys()
        }.store(in: &cancellables)
        loadKeys()
        self.isKeyTutorialClosed = UserDefaultUtils.bool(forKey: .keyTutorialClosed)
        UserDefaultUtils.publisher(for: .keyTutorialClosed).sink { value in
            guard let closed = value as? Bool else {
                return
            }
            self.isKeyTutorialClosed = closed
        }.store(in: &cancellables)
    }
    
    func loadKeys() {
        UserDefaultUtils.set(true, forKey: .hasOpenedKeySelection)
        self.keys = (try? keyManager.storedKeys().filter({ keyManager.currentKey != $0 })) ?? []
        if let activeKey = keyManager.currentKey {
            self.activeKey = keyManager.currentKey
            self.keys.insert(activeKey, at: 0)
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


struct KeySelectionGrid: View {
    
    
    @StateObject var viewModel: KeySelectionGridViewModel
    
    
    var body: some View {
        
        GeometryReader { geo in
            let frame = geo.frame(in: .local)
            let spacing = 2.0
            let side = frame.width/2 - spacing
            let columns = [
                GridItem(.fixed(side), spacing: spacing),
                GridItem(.fixed(side))
            ]
            ScrollView {
                
                if !viewModel.isKeyTutorialClosed {
                    VStack(alignment: .leading) {
                        TutorialCardView(title: L10n.keyTutorialTitle, tutorialText: L10n.keyTutorialText) {
                            UserDefaultUtils.set(true, forKey: .keyTutorialClosed)
                        }
                        .padding(spacing*2)
                        
                    }.opacity(viewModel.isKeyTutorialClosed ? 0.0 : 1.0)
                }
                LazyVGrid(columns: columns, spacing: spacing) {
                    Group {
                        Group {
                            VStack(spacing: spacing) {
                                
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
                                    Text(L10n.createNewKey)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(Color.foregroundSecondary)
                                }
                                let addExistingKeyActive = Binding<Bool> {
                                    viewModel.isShowingAddExistingKeyView
                                } set: { newValue in
                                    viewModel.isShowingAddExistingKeyView = newValue
                                }
                                NavigationLink(isActive: addExistingKeyActive) {
                                    if viewModel.shouldShowPurchaseScreenForKeys {
                                        ProductStoreView(showDismissButton: false)
                                    } else {
                                        KeyEntry(viewModel: .init(keyManager: viewModel.keyManager, dismiss: addExistingKeyActive))
                                    }
                                } label: {
                                    Text(L10n.addExistingKey)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(Color.foregroundSecondary)
                                }

                            }.fontType(.small, on: .background, weight: .bold)

                        }
                        
                        ForEach(viewModel.keys, id: \.id) { key in
                            NavigationLink {
                                KeyDetailView(viewModel: .init(keyManager: viewModel.keyManager, key: key))
                            } label: {
                                KeySelectionGridItem(key: key, isActiveKey: key == viewModel.activeKey)
                            }
                        }
                    }.frame(height: side)
                }
            }
            .screenBlocked()
        }
        .onAppear {
            viewModel.loadKeys()
        }
        .navigationBarTitle(L10n.myKeys)
    }
    
}

struct KeySelectionGridItem_Previews: PreviewProvider {
    static var previews: some View {
        
        KeySelectionGrid(viewModel: .init(keyManager: DemoKeyManager(keys: [            DemoPrivateKey.dummyKey(name: "cats and their people"),
                                                         DemoPrivateKey.dummyKey(name: "dogs"),
                                                         DemoPrivateKey.dummyKey(name: "rats"),
                                                         DemoPrivateKey.dummyKey(name: "mice"),
                                                         DemoPrivateKey.dummyKey(name: "cows"),
                                                         DemoPrivateKey.dummyKey(name: "very very very very very very long name that could overflow"),
                                                                           ]), purchaseManager: AppPurchasedPermissionUtils(), fileManager: DemoFileEnumerator()))
        .preferredColorScheme(.dark)
    }
        
}
