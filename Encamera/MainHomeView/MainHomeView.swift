//
//  MainHomeView.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import SwiftUI
import EncameraCore

class MainHomeViewViewModel: ObservableObject {
    var keyManager: KeyManager
    var purchasedPermissions: PurchasedPermissionManaging
    var fileAccess: FileAccess

    init(keyManager: KeyManager, purchasedPermissions: PurchasedPermissionManaging, fileAccess: FileAccess) {
        self.keyManager = keyManager
        self.purchasedPermissions = purchasedPermissions
        self.fileAccess = fileAccess
    }
}

struct MainHomeView: View {

    @StateObject var viewModel: MainHomeViewViewModel

    var body: some View {
        AlbumGrid(viewModel: .init(keyManager: viewModel.keyManager, purchaseManager: viewModel.purchasedPermissions, fileManager: viewModel.fileAccess))

    }
}

#Preview {
    MainHomeView(viewModel: .init(keyManager: DemoKeyManager(keys: [            DemoPrivateKey.dummyKey(name: "cats and their people"),
        DemoPrivateKey.dummyKey(name: "dogs"),
        DemoPrivateKey.dummyKey(name: "rats"),
        DemoPrivateKey.dummyKey(name: "mice"),
        DemoPrivateKey.dummyKey(name: "cows"),
        DemoPrivateKey.dummyKey(name: "very very very very very very long name that could overflow"),
                                                                   ]), purchasedPermissions: AppPurchasedPermissionUtils(), fileAccess: DemoFileEnumerator()))
}
