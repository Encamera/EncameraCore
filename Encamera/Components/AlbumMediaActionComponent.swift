//
//  AlbumMediaActionComponent.swift
//  Encamera
//
//  Created by Alexander Freas on 24.01.24.
//

import Foundation
import SwiftUI

private enum Constants {
    static let mainRectangleWidth: CGFloat = 327
    static let mainRectangleHeight: CGFloat = 237
    static let mainRectangleCornerRadius: CGFloat = 16
    static let mainRectangleOpacity: Double = 0.50
    static let subRectangleWidth: CGFloat = 64
    static let subRectangleHeight: CGFloat = 64
    static let subRectangleCornerRadius: CGFloat = 16
    static let subRectangleOpacity: Double = 0.10
    static let decorativeEllipseWidth: CGFloat = 32
    static let decorativeEllipseHeight: CGFloat = 32
    static let decorativeEllipseStrokeWidth: CGFloat = 0.75
    static let decorativeEllipseSize: CGFloat = 10.67
    static let contentWidth: CGFloat = 205
    static let contentHeight: CGFloat = 189
    static let titleFontSize: CGFloat = 16
    static let subTitleFontSize: CGFloat = 14
    static let actionTitleFontSize: CGFloat = 14
    static let actionTitleColor: Color = Color(red: 0.78, green: 0.96, blue: 0.20)
}

struct AlbumActionComponent: View {
    let mainTitle: String
    let subTitle: String
    let actionTitle: String
    let imageName: String

    var body: some View {
        ZStack {
            BackgroundRectangle(width: Constants.mainRectangleWidth, height: Constants.mainRectangleHeight, cornerRadius: Constants.mainRectangleCornerRadius, opacity: Constants.mainRectangleOpacity)

            VStack(spacing: 24) {
                ZStack {
                    BackgroundRectangle(width: Constants.subRectangleWidth, height: Constants.subRectangleHeight, cornerRadius: Constants.subRectangleCornerRadius, opacity: Constants.subRectangleOpacity)

                        Image(imageName)
                }

                VStack(spacing: 32) {
                    VStack(spacing: 4) {
                        Text(mainTitle)
                            .fontType(.pt16, weight: .bold)
                        Text(subTitle)
                            .fontType(.pt14)
                            .opacity(0.60)
                    }
                    Button(actionTitle) {

                    }.textButton()
                }
            }
        }
        .frame(width: Constants.mainRectangleWidth, height: Constants.mainRectangleHeight)
    }
}

struct BackgroundRectangle: View {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    var opacity: Double

    var body: some View {

        Rectangle()
            .foregroundColor(.clear)
            .frame(width: width, height: height)
            .background(Color(red: 0.85, green: 0.85, blue: 0.85).opacity(opacity))
            .cornerRadius(cornerRadius)

    }
}

extension Text {
    func customFont(_ weight: Font.Weight? = nil, size: CGFloat) -> some View {
        self.font(Font.custom("Satoshi Variable", size: size).weight(weight ?? .regular))
            .foregroundColor(.white)
            .lineSpacing(24)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Button(action: {

            }, label: {
                AlbumActionComponent(mainTitle: "Create a new memory", subTitle: "Open your camera and take a pic", actionTitle: "Take a picture", imageName: "Album-Camera")
            })

            AlbumActionComponent(mainTitle: "Secure your pics", subTitle: "Import pictures from your camera roll", actionTitle: "Import Pictures", imageName: "Premium-Albums")
        }
    }
}
