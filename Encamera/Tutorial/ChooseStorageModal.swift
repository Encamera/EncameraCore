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

    var hasEntitlement: Bool
    @State var selectedStorage: StorageType?

    var storageSelected: ((StorageType) -> Void)?
    var dismissButtonPressed: () -> ()

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack {
                Spacer()
                ZStack(alignment: .bottom) {
                    ZStack(alignment: .init(horizontal: .trailing, vertical: .top)) {

                        VStack(alignment: .center, spacing: Constants.verticalPadding) {

                            Image("Storage-LockWithKey")

                            Text(L10n.chooseYourStorage)
                                .fontType(.pt24, weight: .bold)

                            Text(L10n.chooseYourStorageDescription)
                                .lineLimit(2, reservesSpace: true)
                                .fontType(.pt16)
                                .multilineTextAlignment(.center)

                            VStack(spacing: 7) {
                                let availabilites = DataStorageAvailabilityUtil
                                    .storageAvailabilities()
                                    .filter({$0.availability == .available })
                                    .sorted(by: {$0.storageType == .local && $1.storageType == .icloud})
                                ForEach(availabilites) { storage in

                                    let selectionBinding = Binding<Bool>(
                                        get: {
                                            selectedStorage == storage.storageType
                                        },
                                        set: { newValue in
                                            selectedStorage = storage.storageType
                                        }
                                    )
                                    Button(action: {
                                        selectedStorage = storage.storageType
                                    }) {
                                        StorageOptionSquare(storageType: storage.storageType, isSelected: selectionBinding, isAvailable: true)

                                    }
                                }
                            }
                            HStack {
                                Button(showUpgradeText ? L10n.upgradeToPremium : L10n.confirmStorage) {
                                    guard let selectedStorage else {
                                        return
                                    }
                                    storageSelected?(selectedStorage)
                                }
                                .disabled(selectedStorage == nil)
                                .primaryButton(enabled: selectedStorage != nil)
                            }
                        }
                        .padding(.init(top: 40, leading: 16, bottom: 40, trailing: 16))
                        .background(Color.tutorialViewBackground)
                        .cornerRadius(AppConstants.defaultCornerRadius)
                        DismissButton(action: dismissButtonPressed).padding()
                    }.frame(height: 550)
                }.padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .background(.ultraThinMaterial)



    }

    private var showUpgradeText: Bool {
        selectedStorage != nil && selectedStorage == .icloud && !hasEntitlement
    }
}

struct ChooseStorageModal_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.background

            ChooseStorageModal(hasEntitlement: false, storageSelected: { selected in

            }, dismissButtonPressed: {

            })

        }.preferredColorScheme(.dark)

    }
}
