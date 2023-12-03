//
//  CameraZoomControlButtons.swift
//  Encamera
//
//  Created by Alexander Freas on 03.12.23.
//

import SwiftUI
import EncameraCore

private struct CameraZoomControlButton: View {

    var zoomScale: ZoomLevel

    @Binding var isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .foregroundColor(.black.opacity(0.44))
            Text("\(zoomScale.rawValue.formatted())x")
                .foregroundColor(isSelected ? .yellow : .white)
                .fontType(isSelected ? .rajdhaniBold : .rajdhaniBoldSmall)

        }.padding(isSelected ? 4 : 10)
            .animation(.easeInOut.speed(4), value: isSelected)
    }

}

struct CameraZoomControlButtons: View {

    var supportedZoomScales: [ZoomLevel]
    @Binding var selectedZoomScale: ZoomLevel
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
    var zoom: ZoomLevel = .x1
    let selectedZoomScale = Binding<ZoomLevel>(get: { zoom }, set: { zoom = $0 })
    return CameraZoomControlButtons(supportedZoomScales: [.x05, .x1], selectedZoomScale: selectedZoomScale).frame(width: 175, height: 50)
}
