//
//  CameraZoomControlButtons.swift
//  Encamera
//
//  Created by Alexander Freas on 03.12.23.
//

import SwiftUI

private struct CameraZoomControlButton: View {

    var zoomScale: CGFloat

    @Binding var isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .foregroundColor(.black.opacity(0.44))
            Text("\(zoomScale.formatted())x")
                .foregroundColor(isSelected ? .yellow : .white)
                .fontType(isSelected ? .rajdhaniBold : .rajdhaniBoldSmall)

        }.padding(isSelected ? 4 : 10)
            .animation(.easeInOut.speed(4), value: isSelected)
    }

}

struct CameraZoomControlButtons: View {

    var supportedZoomScales: [CGFloat]
    @Binding var selectedZoomScale: CGFloat
    var body: some View {
        ZStack() {
            HStack(spacing: 0) {
                ForEach(supportedZoomScales, id: \.self) { zoomScale in

                    let selectedBinding = Binding<Bool>  {
                        selectedZoomScale == zoomScale
                    } set: { selected in
                        selectedZoomScale = zoomScale
                    }

                    CameraZoomControlButton(zoomScale: zoomScale, isSelected: selectedBinding)
                        .onTapGesture {
                            selectedZoomScale = zoomScale
                        }
                }
            }
        }
        .background(Color(red: 0.27, green: 0.27, blue: 0.27).opacity(0.44))
        .cornerRadius(100)
    }
}

#Preview {
    var zoom: CGFloat = 1.0
    let selectedZoomScale = Binding<CGFloat>(get: { zoom }, set: { zoom = $0 })
    return CameraZoomControlButtons(supportedZoomScales: [0.5, 1], selectedZoomScale: selectedZoomScale).frame(width: 175, height: 50)
}
