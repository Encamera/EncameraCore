//
//  StepIndicator.swift
//  Encamera
//
//  Created by Alexander Freas on 04.10.23.
//

import Foundation
import SwiftUI

struct StepIndicator: View {
    let numberOfItems: Int
    let currentItem: Int

    init(numberOfItems: Int, currentItem: Int) {
        self.numberOfItems = max(0, numberOfItems)
        self.currentItem = min(max(0, currentItem), numberOfItems - 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<numberOfItems, id: \.self) { index in
                if index == currentItem {
                    Ellipse()
                        .foregroundColor(.clear)
                        .frame(width: 12, height: 12)
                        .overlay(Ellipse()
                                    .inset(by: 1)
                                    .stroke(Color.white, lineWidth: 1))
                } else {
                    Ellipse()
                        .fill(index < currentItem ? Color.white.opacity(0.20) : Color(red: 0.21, green: 0.21, blue: 0.21))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: CGFloat(numberOfItems * 6 + 12 + (numberOfItems - 1) * 8), height: 12)
    }
}

struct StepIndicator_Previews: PreviewProvider {
    static var previews: some View {
        StepIndicator(numberOfItems: 5, currentItem: 1)
            .previewLayout(.sizeThatFits)
            .background(Color.black)
    }
}
