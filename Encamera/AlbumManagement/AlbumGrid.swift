//
//  AlbumGrid.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import SwiftUI
import EncameraCore
import Combine

class AlbumGridViewModel: ObservableObject {
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
        UserDefaultUtils.set(true, forKey: .hasOpenedAlbum)
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


struct AlbumGrid: View {


    @StateObject var viewModel: AlbumGridViewModel


    var body: some View {
        VStack(alignment: .leading) {
            Text(L10n.albumsTitle)
                .fontType(.large, weight: .bold)

            GeometryReader { geo in
                let frame = geo.frame(in: .local)
                let spacing = 17.0
                let side = frame.width/2 - spacing
                let columns = [
                    GridItem(.fixed(side), spacing: spacing),
                    GridItem(.fixed(side))
                ]
                ScrollView(showsIndicators: false) {

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
                                AlbumBaseGridItem(image: Image("Albums-Add"), title: L10n.createNewAlbum, subheading: nil, width: side, strokeStyle: StrokeStyle(lineWidth: 2, dash: [10], dashPhase: 0.0), shouldResizeImage: false)
                            }


                            ForEach(viewModel.keys, id: \.id) { key in
                                NavigationLink {
                                    AlbumDetailView(viewModel: .init(keyManager: viewModel.keyManager, key: key))
                                } label: {
                                    AlbumGridItem(key: key, width: side)
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
#Preview {
    AlbumGrid(viewModel: .init(keyManager: DemoKeyManager(keys: [            DemoPrivateKey.dummyKey(name: "cats and their people"),
                                                                             DemoPrivateKey.dummyKey(name: "dogs"),
                                                                             DemoPrivateKey.dummyKey(name: "rats"),
                                                                             DemoPrivateKey.dummyKey(name: "mice"),
                                                                             DemoPrivateKey.dummyKey(name: "cows"),
                                                                             DemoPrivateKey.dummyKey(name: "very very very very very very long name that could overflow"),
                                                                ]), purchaseManager: AppPurchasedPermissionUtils(), fileManager: DemoFileEnumerator()))
}
