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
    let textAlignment: Alignment
    let titleFont: EncameraFont

    init(title: String? = nil,
         isToolbar: Bool = false,
         textAlignment: Alignment = .leading,
         titleFont: EncameraFont = .pt20,
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
        self.textAlignment = textAlignment
        self.titleFont = titleFont

    }

    init(isToolbar: Bool = false,
         textAlignment: Alignment = .leading,
         titleFont: EncameraFont = .pt20,
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
        self.titleFont = titleFont
        self.textAlignment = textAlignment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                leftContent().frame(width: 20)
                if let title {
                    Text(title)
                        .fontType(titleFont, weight: .bold)
                        .frame(maxWidth: .infinity, alignment: textAlignment)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0) // Balances right content
                rightContent()

            }
            .frame(height: 44)
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
