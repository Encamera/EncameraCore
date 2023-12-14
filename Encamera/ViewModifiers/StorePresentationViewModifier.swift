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
    var fromViewName: String
    var purchaseAction: PurchaseResultAction?
    func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                ProductStoreView(fromView: fromViewName, purchaseAction: purchaseAction)
                    .transition(.move(edge: .bottom))
            }
        }
    }
}

extension View {
    func productStore(isPresented: Binding<Bool>, fromViewName: String, purchaseAction: PurchaseResultAction? = nil) -> some View {
        self.modifier(StorePresentationViewModifier(isPresented: isPresented, fromViewName: fromViewName, purchaseAction: purchaseAction))
    }
}
