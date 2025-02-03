//
//  ViewHeader.swift
//  Encamera
//
//  Created by Alexander Freas on 22.09.24.
//
import SwiftUI

struct ViewHeader<RightContent: View, LeftContent: View, CenterContent: View>: View {

    let title: String?
    let rightContent: (() -> RightContent)
    let leftContent: (() -> LeftContent)
    let centerContent: (() -> CenterContent)?
    let hasCenterContent: Bool
    let isToolbar: Bool

    init(title: String? = nil,
         isToolbar: Bool = false,
         rightContent: @escaping ( () -> RightContent) = EmptyView.init,
         leftContent: @escaping ( () -> LeftContent) = EmptyView.init,
         centerContent: @escaping (() -> CenterContent) = EmptyView.init
    ) {
        self.title = title
        self.rightContent = rightContent
        self.leftContent = leftContent
        self.centerContent = nil
        self.hasCenterContent = false
        self.isToolbar = isToolbar
    }

    init(isToolbar: Bool = false,
         leftContent: @escaping ( () -> LeftContent) = EmptyView.init,
         centerContent: @escaping (() -> CenterContent) = EmptyView.init,
         rightContent: @escaping ( () -> RightContent) = EmptyView.init
    ) {
        self.rightContent = rightContent
        self.leftContent = leftContent
        self.centerContent = centerContent
        self.hasCenterContent = true
        self.title = nil
        self.isToolbar = isToolbar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                leftContent().frame(width: 20)
                if let title {
                    Text(title)
                        .fontType(.pt18, weight: .bold) // Ensure consistent font size
                        .frame(minHeight: 44, alignment: .center) // Match button height for alignment
                        .alignmentGuide(VerticalAlignment.center) { $0[VerticalAlignment.center] } // Aligns baseline
//                        .background(Color.random)
                }

                Spacer(minLength: 0) // Balances right content

                rightContent()
                    .frame(minHeight: 44) // Ensures alignment with title text
//                    .background(Color.random)

            }
            .frame(height: 44) // Set a fixed height for consistent alignment

            .if(isToolbar == false) { content in
                content
                    .padding([.leading, .trailing], Spacing.pt24.value)
                    .padding([.top, .bottom], Spacing.pt8.value)
            }

            if isToolbar == false {
                GradientDivider()
            }
        }
    }
}
