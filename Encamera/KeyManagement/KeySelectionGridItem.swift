//
//  KeySelectionGridItem.swift
//  Encamera
//
//  Created by Alexander Freas on 28.11.22.
//

import SwiftUI

actor KeyInfoFetcher {
    
}

class KeySelectionGridItemModel: ObservableObject {
    var imageCount: Int?
    @Published var leadingImage: UIImage?
    var keyName: String
    var isActiveKey: Bool = false
    var storageModel: DataStorageModel?
    var storageType: StorageType? {
        storageModel?.storageType
    }
    var fileReader: FileReader

    init(key: PrivateKey, isActiveKey: Bool) {
        keyName = key.name
        storageModel = DataStorageUserDefaultsSetting().storageModelFor(keyName: key.name)
        fileReader = DiskFileAccess()
        self.isActiveKey = isActiveKey
        Task {
            await fileReader.configure(
                with: key,
                storageSettingsManager: DataStorageUserDefaultsSetting()
            )
            
        }
    }
    
    init(imageCount: Int, leadingImage: UIImage? = nil, keyName: String, storageType: StorageType? = .icloud, fileReader: FileReader) {
        self.imageCount = imageCount
        self.leadingImage = leadingImage
        self.keyName = keyName
        self.storageModel = storageType?.modelForType.init(keyName: keyName)
        self.fileReader = fileReader
    }
    
    func load() {
        Task {
            self.imageCount = storageModel?.countOfFiles()
            let thumb = try await fileReader.loadLeadingThumbnail()
            await MainActor.run {
                self.leadingImage = thumb
            }
        }
    }
    
}

struct KeySelectionGridItem: View {
    
    @StateObject var viewModel: KeySelectionGridItemModel
    
    
    var body: some View {
            VStack {
                if viewModel.isActiveKey {
                    Text("Active")
                        .fontType(.extraSmall)
                        .padding(4)
                        .frame(maxWidth: .infinity)
                        .background {
                            Color.green
                        }
                }
                
                HStack {
                    Text(viewModel.keyName)
                        .fontType(.mediumSmall)
                    
                    Spacer()

                }.padding()
                Spacer()
                HStack {
                    if let imageCount = viewModel.imageCount {
                        Text("\(imageCount) \(Image(systemName: "photo.fill"))")
                    }
                    Spacer()

                    if let iconName = viewModel.storageType?.iconName {
                        Image(systemName: iconName)
                            .padding(2)
                    }
                                    }
                .fontType(.small)
                .padding(.vertical, 3)
            }
            .background {
                if let leadingImage = viewModel.leadingImage {
                    Image(uiImage: leadingImage)
                        .resizable()
                        .aspectRatio(contentMode:.fill)
                        .opacity(0.3)
                }
            }
//            .frame(maxWidth: .infinity)
//            .aspectRatio(contentMode:.fill)
            .contentShape(Rectangle())
            .clipped()

        .task {
            viewModel.load()
        }
        
    }
}

class KeySelectionGridViewModel: ObservableObject {
    var keys: [PrivateKey] = []
    var activeKey: PrivateKey?
    var keyManager: KeyManager
    
    
    
    init(keyManager: KeyManager) {
        if let storedKeys = try? keyManager.storedKeys().filter({ keyManager.currentKey != $0 }) {
            self.keys = storedKeys
        }
        self.activeKey = keyManager.currentKey
        self.keyManager = keyManager
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
                LazyVGrid(columns: columns, spacing: spacing) {
                    Group {
                        Group {
                            Text("New Key")
                            Text("Backup")
                        }
                        if let activeKey = viewModel.activeKey {
                            KeySelectionGridItem(viewModel: .init(key: activeKey, isActiveKey: true))
                        }
                        ForEach(viewModel.keys) { key in
                            KeySelectionGridItem(viewModel: .init(key: key, isActiveKey: false))
                            
                        }
                    }.frame(height: side)
                }
            }
        }
    }
    
//    private func gridItemFor(key: PrivateKey) -> some View {
}

private extension View {
    func navigationLinkFor(key: PrivateKey) -> some View {
        NavigationLink {
            
        } label: {
            self
        }
    }
}

struct KeySelectionGridItem_Previews: PreviewProvider {
    static var previews: some View {
        
        KeySelectionGrid(viewModel: .init(keyManager: DemoKeyManager(keys: [            DemoPrivateKey.dummyKey(name: "cats and their people"),
                                                         DemoPrivateKey.dummyKey(name: "dogs"),
                                                         DemoPrivateKey.dummyKey(name: "rats"),
                                                         DemoPrivateKey.dummyKey(name: "mice"),
                                                         DemoPrivateKey.dummyKey(name: "cows"),
                                                         DemoPrivateKey.dummyKey(name: "very long name that could overflow"),
                                            ])))

    }
}
