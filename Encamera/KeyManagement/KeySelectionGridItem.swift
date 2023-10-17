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
struct GeneralPurposeView: View {

    @State var image: Image?
    var title: String
    var subheading: String?
    var width: CGFloat
    var strokeStyle: StrokeStyle? = nil
    var shouldResizeImage: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .stroke(style: strokeStyle ?? StrokeStyle(lineWidth: 0))
                .background {
                if let image = image {
                    if shouldResizeImage {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        image
                    }

                } else {
                    Color.inputFieldBackgroundColor // replace with an actual color or view
                }
            }
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .circular))
            .padding(.bottom, 12)


            Text(title)
                .fontType(.extraSmall, weight: .bold) // replace with actual font

//            if let subheading = subheading {
                Text(subheading ?? "")
                .lineLimit(1, reservesSpace: true)
                    .fontType(.extraSmall) // replace with actual font
//            }
        }
    }
}
struct KeySelectionGridItem: View {

    @ObservedObject var viewModel: KeySelectionGridItemModel
    @State var imageCount: Int?
    @State var leadingImage: UIImage?
    var keyName: String
    var width: CGFloat

    init(key: PrivateKey, width: CGFloat) {
        keyName = key.name
        self.viewModel = KeySelectionGridItemModel(key: key)
        self.width = width
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
        
        GeneralPurposeView(image: leadingImage != nil ? Image(uiImage: leadingImage!) : nil,
                           title: keyName,
                           subheading: imageCount != nil ? "\(imageCount!) items" : nil,
                           width: width)
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
        VStack(alignment: .leading) {
            Text("Albums")
                .fontType(.large, weight: .bold)

            GeometryReader { geo in
                let frame = geo.frame(in: .local)
                let spacing = 17.0
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
                        }.opacity(viewModel.isKeyTutorialClosed ? 0.0 : 1.0)
                    }
                    LazyVGrid(columns: columns, spacing: spacing) {
                        Group {
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
                                    GeneralPurposeView(image: Image("Albums-Add"), title: L10n.createNewAlbum, subheading: nil, width: side, strokeStyle: StrokeStyle(lineWidth: 2, dash: [10], dashPhase: 0.0), shouldResizeImage: false)

                                }


                            ForEach(viewModel.keys, id: \.id) { key in
                                NavigationLink {
                                    KeyDetailView(viewModel: .init(keyManager: viewModel.keyManager, key: key))
                                } label: {
                                    KeySelectionGridItem(key: key, width: side)
                                }
                            }

                        }.frame(height: side + 60)
                    }
                }
                .screenBlocked()
            }
            .onAppear {
                viewModel.loadKeys()
            }
            .navigationBarTitle(L10n.myKeys)
        }
        .padding(24)
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
