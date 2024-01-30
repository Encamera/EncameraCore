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

struct CustomComponent: View {
    let mainTitle: String
    let subTitle: String
    let actionTitle: String

    var body: some View {
        ZStack {
            BackgroundRectangle(width: Constants.mainRectangleWidth, height: Constants.mainRectangleHeight, cornerRadius: Constants.mainRectangleCornerRadius, opacity: Constants.mainRectangleOpacity)

            VStack(spacing: 24) {
                ZStack {
                    BackgroundRectangle(width: Constants.subRectangleWidth, height: Constants.subRectangleHeight, cornerRadius: Constants.subRectangleCornerRadius, opacity: Constants.subRectangleOpacity)

                    HStack(spacing: 0) {
                        DecorativeEllipse(width: Constants.decorativeEllipseWidth, height: Constants.decorativeEllipseHeight)
                    }
                }

                VStack(spacing: 32) {
                    VStack(spacing: 4) {
                        Text(mainTitle)
                            .customFont(.bold, size: Constants.titleFontSize)
                        Text(subTitle)
                            .customFont(size: Constants.subTitleFontSize)
                            .opacity(0.60)
                    }
                    Text(actionTitle)
                        .customFont(.bold, size: Constants.actionTitleFontSize)
                        .foregroundColor(Constants.actionTitleColor)
                }
            }
            .frame(width: Constants.contentWidth, height: Constants.contentHeight)
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
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .inset(by: 0.50)
                    .stroke(.white, lineWidth: 0.50)
            )
    }
}

struct DecorativeEllipse: View {
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .foregroundColor(.clear)
                .frame(width: width, height: height)
            Ellipse()
                .foregroundColor(.clear)
                .frame(width: Constants.decorativeEllipseSize, height: Constants.decorativeEllipseSize)
                .overlay(Ellipse().stroke(.white, lineWidth: Constants.decorativeEllipseStrokeWidth))
        }
        .frame(width: width, height: height)
    }
}

extension Text {
    func customFont(_ weight: Font.Weight? = nil, size: CGFloat) -> some View {
        self.font(Font.custom("Satoshi Variable", size: size).weight(weight ?? .regular))
            .foregroundColor(.white)
            .lineSpacing(24)
    }
}

struct ContentView: View {
    var body: some View {
        CustomComponent(mainTitle: "Create a new memory", subTitle: "Open your camera and take a pic", actionTitle: "Take a picture")
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
