//
//  StepIndicator.swift
//  Encamera
//
//  Created by Alexander Freas on 04.10.23.
//

import Foundation
import SwiftUI

private enum Constants {
    static let minimumItems: Int = 0
    static let minimumCurrentItem: Int = 0
    static let ellipseFullWidth: CGFloat = 12
    static let ellipseFullHeight: CGFloat = 12
    static let ellipseSmallWidth: CGFloat = 6
    static let ellipseSmallHeight: CGFloat = 6
    static let strokeLineWidth: CGFloat = 1
    static let spacing: CGFloat = 8
}

struct StepIndicator: View {
    let numberOfItems: Int
    let currentItem: Int

    init(numberOfItems: Int, currentItem: Int) {
        self.numberOfItems = max(Constants.minimumItems, numberOfItems)
        self.currentItem = min(max(Constants.minimumCurrentItem, currentItem), numberOfItems - 1)
    }

    var body: some View {
        HStack(spacing: Constants.spacing) {
            ForEach(Constants.minimumItems..<numberOfItems, id: \.self) { index in
                if index == currentItem {
                    Ellipse()
                        .foregroundColor(.clear)
                        .frame(width: Constants.ellipseFullWidth, height: Constants.ellipseFullHeight)
                        .overlay(Ellipse()
                                    .inset(by: Constants.strokeLineWidth)
                                    .stroke(Color.white, lineWidth: Constants.strokeLineWidth))
                } else {
                    Ellipse()
                        .fill(index < currentItem ? Color.stepIndicatorActive : Color.stepIndicatorInactive)
                        .frame(width: Constants.ellipseSmallWidth, height: Constants.ellipseSmallHeight)
                }
            }
        }
        .frame(width: CGFloat(numberOfItems) * Constants.ellipseSmallWidth + Constants.ellipseFullWidth + CGFloat(numberOfItems - 1) * Constants.spacing, height: Constants.ellipseFullHeight)
    }
}


struct StepIndicator_Previews: PreviewProvider {
    static var previews: some View {
        StepIndicator(numberOfItems: 5, currentItem: 1)
            .previewLayout(.sizeThatFits)
            .background(Color.black)
    }
}
