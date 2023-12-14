//
//  ChooseStorageModalViewModifier.swift
//  Encamera
//
//  Created by Alexander Freas on 14.12.23.
//

import Foundation
import SwiftUI
import EncameraCore

typealias DidSelectStorage = (StorageType, Bool) -> Void
struct ChooseStorageModalViewModifier: ViewModifier {

    @Binding var isPresented: Bool
    var purchasedPermissions: PurchasedPermissionManaging
    var album: Album
    var didSelectStorage: DidSelectStorage
    var dismissAction: () -> ()
    func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                let hasEntitlement = purchasedPermissions.hasEntitlement()
                ChooseStorageModal(hasEntitlement: hasEntitlement, selectedStorage: album.storageOption, storageSelected: { storage in
                    didSelectStorage(storage, hasEntitlement)
                }, dismissButtonPressed: dismissAction)
            }

        }

    }
}

extension View {

    @ViewBuilder
    func chooseStorageModal(isPresented: Binding<Bool>, album: Album?, purchasedPermissions: PurchasedPermissionManaging, didSelectStorage: @escaping DidSelectStorage, dismissAction: @escaping () -> ()) -> some View {
        if let album {
            self.modifier(ChooseStorageModalViewModifier(isPresented: isPresented,
                                                         purchasedPermissions: purchasedPermissions,
                                                         album: album,
                                                         didSelectStorage: didSelectStorage,
                                                         dismissAction: dismissAction
                                                        ))
        } else {
            self
        }
    }
}
