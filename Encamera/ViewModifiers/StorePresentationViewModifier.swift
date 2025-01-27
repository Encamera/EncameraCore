//
//  StorePresentationViewModifier.swift
//  Encamera
//
//  Created by Alexander Freas on 14.12.23.
//

import Foundation
import SwiftUI

struct StorePresentationViewModifier: ViewModifier {

    @Binding var isPresented: Bool
    @EnvironmentObject var appModalStateModel: AppModalStateModel

    var fromViewName: String
    var purchaseAction: PurchaseResultAction?
    func body(content: Content) -> some View {
        ZStack {
            content
                .onChange(of: appModalStateModel.currentModal, { oldValue, newValue in
                    if case .purchaseView = newValue {
                        isPresented = true
                    } else {
                        isPresented = false
                    }
                })
                .onChange(of: isPresented, { oldValue, newValue in
                    if newValue == true {
                        appModalStateModel.currentModal = .purchaseView(context: PurchaseViewContext(sourceView: fromViewName, purchaseAction: purchaseAction))
                    } else {
                        appModalStateModel.currentModal = nil
                    }
                })
        }
    }
}

extension View {

    func productStorefront(isPresented: Binding<Bool>, fromViewName: String, purchaseAction: PurchaseResultAction? = nil) -> some View {
        self.modifier(StorePresentationViewModifier(isPresented: isPresented, fromViewName: fromViewName, purchaseAction: purchaseAction))
    }
}
