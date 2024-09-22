//
//  ViewHeader.swift
//  Encamera
//
//  Created by Alexander Freas on 22.09.24.
//
import SwiftUI

struct ViewHeader<Content: View>: View {

    let title: String
    let rightContent: (() -> Content)?

    init(title: String, rightContent: ( () -> Content)? = EmptyView.init) {
        self.title = title
        self.rightContent = rightContent
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                    .fontType(.pt20, weight: .bold)
                Spacer()
                rightContent?()
            }
            .frame(height: 45)
            .padding([.leading, .trailing], Spacing.pt24.value)
            .padding([.top, .bottom], Spacing.pt16.value)
            GradientDivider()
        }
    }
}
