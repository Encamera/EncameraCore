//
//  FirstPhotoTaken.swift
//  Encamera
//
//  Created by Alexander Freas on 02.11.22.
//

import SwiftUI
import EncameraCore

private enum Constants {
    static var storageItemSpacing: CGFloat = 20
    static var verticalPadding: CGFloat = 25
}

struct ChooseStorageModal: View {

    var hasPurchasedPremium: Bool
    @State var selectedStorage: StorageType?

    var buttonPressed: ((StorageType) -> Void)?




    var body: some View {
        ZStack {

            ZStack {
                VStack(alignment: .center, spacing: Constants.verticalPadding) {
                    Image("Storage-LockWithKey")

                    Text(L10n.chooseYourStorage)
                        .fontType(.pt24, weight: .bold)

                    Text(L10n.chooseYourStorageDescription)
                        .fontType(.pt16)
                        .multilineTextAlignment(.center)

                    GeometryReader { geo in
                        HStack(spacing: Constants.storageItemSpacing) {
                            let availabilites = DataStorageAvailabilityUtil
                                .storageAvailabilities()
                                .sorted(by: {$0.storageType == .local && $1.storageType == .icloud})
                            ForEach(availabilites) { storage in

                                let selectionBinding = Binding<Bool>(
                                    get: {
                                        selectedStorage == storage.storageType
                                    },
                                    set: { newValue in                                    selectedStorage = storage.storageType
                                    }
                                )
                                Button(action: {
                                    selectedStorage = storage.storageType
                                }) {
                                    StorageOptionSquare(storageType: storage.storageType, isSelected: selectionBinding, isAvailable: true)
                                        .frame(width: (geo.size.width - Constants.storageItemSpacing) / CGFloat(availabilites.count), height: 200)
                                }
                            }
                        }
                    }
                    HStack {
                        Button(showUpgradeText ? L10n.upgradeToPremium : L10n.confirmStorage) {
                            guard let selectedStorage else {
                                return
                            }
                            buttonPressed?(selectedStorage)
                        }
                        .disabled(selectedStorage == nil)
                        .primaryButton(on: .darkBackground, enabled: selectedStorage != nil)
                    }
                }
                .padding(.init(top: 40, leading: 16, bottom: 40, trailing: 16))
                .background(Color.tutorialViewBackground)
                .cornerRadius(AppConstants.defaultCornerRadius)
                .frame(height: 550)
            }.padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .background(.ultraThinMaterial)



    }

    private var showUpgradeText: Bool {
        selectedStorage != nil && selectedStorage == .icloud && !hasPurchasedPremium
    }
}

struct ChooseStorageModal_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.background

            ChooseStorageModal(hasPurchasedPremium: false) { selected in

            }

        }.preferredColorScheme(.dark)

    }
}
