//
//  ImageStepIndicator.swift
//  Encamera
//
//  Created by Alexander Freas on 10.10.23.
//

import Foundation
import SwiftUI
enum ImageStepIndicatorConstants {
    static let initialActiveIndex: Int = 0
    static let spacing: CGFloat = 4
    static let activeRectangleWidth: CGFloat = 30
    static let height: CGFloat = 8
    static let frameHeight: CGFloat = 12
}

struct ImageStepIndicator: View {
    @Binding var activeIndex: Int
    var numberOfItems: Int
    var body: some View {
        HStack(spacing: ImageStepIndicatorConstants.spacing) {
            ForEach(0..<numberOfItems, id: \.self) { index in
                let isActive = activeIndex == index
                Rectangle()
                    .foregroundColor(.clear)
                    .frame(width: isActive ? ImageStepIndicatorConstants.activeRectangleWidth : ImageStepIndicatorConstants.height,
                           height: ImageStepIndicatorConstants.height)
                    .background(isActive ? .white : Color.stepIndicatorInactive)
                    .cornerRadius(ImageStepIndicatorConstants.height / 2)
                    .animation(.easeInOut, value: activeIndex)
            }
        }
        .frame(height: ImageStepIndicatorConstants.frameHeight) // Increase the height to accommodate the larger ellipses
    }
}

struct ImageStepIndicator_Previews: PreviewProvider {

    struct Container: View {
        @State var activeIndex: Int = 1

        var body: some View {
            VStack {
                Text("Active Index \(activeIndex)")
                ImageStepIndicator(activeIndex: $activeIndex, numberOfItems: 5)
                Button {
                    activeIndex += 1
                } label: {
                    Text("Increase")
                }

            }
        }
    }
    static var previews: some View {
        Container()
    }
}
