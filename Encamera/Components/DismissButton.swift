//
//  DismissButton.swift
//  Encamera
//
//  Created by Alexander Freas on 14.12.23.
//

import SwiftUI

struct DismissButton: View {

    var action: () -> Void
    var body: some View {
        Button(action: action, label: {
            Image("Button-Dismiss")

        })
        .buttonStyle(.borderless)
    }
}

#Preview {
    DismissButton() {

    }
}
