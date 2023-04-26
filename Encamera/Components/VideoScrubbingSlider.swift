//
//  VideoScrubbingSlider.swift
//  Encamera
//
//  Created by Alexander Freas on 26.04.23.
//

import Foundation
import SwiftUI

import SwiftUI

struct VideoScrubbingSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    
    @State private var lastCoordinateValue: CGFloat = 0.0

    private func normalizedValue() -> CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
    
    private func denormalizeValue(_ normalizedValue: CGFloat) -> Double {
        Double(normalizedValue) * (range.upperBound - range.lowerBound) + range.lowerBound
    }
    
    var body: some View {
        GeometryReader { geometry in
            let thumbSize = geometry.size.height * 0.8
            let radius = geometry.size.height * 0.5
            let minValue = geometry.size.width * 0.015
            let maxValue = (geometry.size.width * 0.98) - thumbSize
            
            ZStack {
                RoundedRectangle(cornerRadius: radius)
                    .foregroundColor(.foregroundSecondary)
                HStack {
                    Circle()
                        .foregroundColor(Color.foregroundPrimary)
                        .frame(width: thumbSize, height: thumbSize)
                        .offset(x: minValue + (maxValue - minValue) * normalizedValue())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { gestureValue in
                                    if (abs(gestureValue.translation.width) < 0.1) {
                                        self.lastCoordinateValue = self.normalizedValue()
                                    }
                                    let proposedValue = self.lastCoordinateValue + gestureValue.translation.width / (maxValue - minValue)
                                    let clampedValue = min(max(proposedValue, 0), 1)
                                    self.value = denormalizeValue(clampedValue)
                                }
                        )
                    Spacer()
                }
            }
        }
    }
}


struct VideoScrubbingSlider_Previews: PreviewProvider {
    static var previews: some View {
        VideoScrubbingSlider(value: .constant(4), range: 0...10)
            .frame(width: 300, height: 20)
            .preferredColorScheme(.dark)
    }
}
