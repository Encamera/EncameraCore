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
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    .secondary,
                    .clear,
                    Color(uiColor: .systemGray5)
                )
        })
        .buttonStyle(.borderless)
        .opacity(0.8)
        .font(.title)
    }
}

#Preview {
    DismissButton() {

    }
}
