//
//  ImageWithBackgroundRectangle.swift
//  Encamera
//
//  Created by Alexander Freas on 18.06.24.
//

import Foundation
import SwiftUI

private enum Constants {
    static let defaultWidth: CGFloat = 64
    static let defaultHeight: CGFloat = 64
    static let defaultCornerRadius: CGFloat = 16
    static let defaultOpacity: Double = 0.10
}

struct ImageWithBackgroundRectangle: View {

    let imageName: String
    let rectWidth: CGFloat
    let rectHeight: CGFloat
    let rectCornerRadius: CGFloat
    let rectOpacity: Double

    init(imageName: String, rectWidth: CGFloat = Constants.defaultWidth, rectHeight: CGFloat = Constants.defaultHeight, rectCornerRadius: CGFloat = Constants.defaultCornerRadius, rectOpacity: Double = Constants.defaultOpacity) {
        self.imageName = imageName
        self.rectWidth = rectWidth
        self.rectHeight = rectHeight
        self.rectCornerRadius = rectCornerRadius
        self.rectOpacity = rectOpacity
        
    }


    var body: some View {
        ZStack {
            BackgroundRectangle(
                cornerRadius: rectCornerRadius,
                opacity: rectOpacity,
                color: .white
            )

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: rectWidth/2, height: rectHeight/2)
        }.frame(width: rectWidth, height: rectHeight)
    }
}


