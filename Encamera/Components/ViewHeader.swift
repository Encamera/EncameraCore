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

    init(title: String? = nil,
         rightContent: @escaping ( () -> RightContent) = EmptyView.init,
         leftContent: @escaping ( () -> LeftContent) = EmptyView.init,
         centerContent: @escaping (() -> CenterContent) = EmptyView.init
    ) {
        self.title = title
        self.rightContent = rightContent
        self.leftContent = leftContent
        self.centerContent = nil
        self.hasCenterContent = false
    }

    init(leftContent: @escaping ( () -> LeftContent) = EmptyView.init,
         centerContent: @escaping (() -> CenterContent) = EmptyView.init,
         rightContent: @escaping ( () -> RightContent) = EmptyView.init
    ) {
        self.rightContent = rightContent
        self.leftContent = leftContent
        self.centerContent = centerContent
        self.hasCenterContent = true
        self.title = nil
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                leftContent().frame(width: 20)
                if hasCenterContent {
                    Spacer()
                    centerContent?()
                    Spacer()
                }
                if let title {
                    Text(title)
                        .fontType(.pt20, weight: .bold)
                }
                Spacer()
                rightContent()
            }
            .frame(height: 45)
            .padding([.leading, .trailing], Spacing.pt24.value)
            .padding([.top, .bottom], Spacing.pt8.value)
            GradientDivider()
        }
    }
}
