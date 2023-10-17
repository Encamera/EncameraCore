//
//  TopCameraControlsView.swift
//  Encamera
//
//  Created by Alexander Freas on 26.04.23.
//

import Foundation
import SwiftUI
import AVFoundation
import EncameraCore
import Combine

class TopCameraControlsViewViewModel: ObservableObject {
    
    private var cancellables = Set<AnyCancellable>()

    init() {

    }
}

struct TopCameraControlsView: View {
    
    @StateObject var viewModel: TopCameraControlsViewViewModel

    @Binding var isRecordingVideo: Bool
    @Binding var recordingDuration: CMTime
    @Binding var currentAlbumName: String

    @Binding var flashMode: AVCaptureDevice.FlashMode
    var closeButtonTapped: () -> ()
    var flashButtonPressed: () -> ()
    let cornerRadius = 30.0
    var body: some View {
        HStack(spacing: 0) {
            Button {
                closeButtonTapped()
            } label: {
                Image("Camera-Close")
                    .frame(width: 28, height: 28)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("My Album")
                    .fontType(.pt10, on: .background)
                    .tracking(0.20)
                Image("Camera-Album-Arrow")
                    .frame(width: 14, height: 14)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .background(Color(red: 1, green: 1, blue: 1).opacity(0.10))
            .cornerRadius(800)
            .frame(width: 100)
            Spacer()
            flashButton
                .frame(width: 28, height: 28)
        }
        .padding(EdgeInsets(top: 50, leading: 16, bottom: 16, trailing: 16))
        .background(.ultraThinMaterial)
        .frame(height: 102)

    }

    private var flashButton: some View {
        Button(action: {
            flashButtonPressed()
        }, label: {
            Image("Camera-Flash")
                .foregroundColor(flashMode.colorForMode)
                .frame(width: 44, height: 44)
        })
    }
    private var durationText: some View {
        Text(recordingDuration.durationText)
            .fontType(.small)
            .padding(5)
            .background(Color.videoRecordingIndicator)
            .cornerRadius(10)
            .opacity(isRecordingVideo ? 1.0 : 0.0)

    }
}

//struct TopCameraControlsView_Previews: PreviewProvider {
//    static var previews: some View {
//        TopCameraControlsView(viewModel: .init(purchaseManager: DemoPurchasedPermissionManaging()), showingKeySelection: .constant(false), isRecordingVideo: .constant(false), recordingDuration: .constant(CMTime(seconds: 0, preferredTimescale: 1)), currentKeyName: .constant("DefaultKey"), flashMode: .constant(.off), settingsButtonTapped: {}, flashButtonPressed: {})
//            .preferredColorScheme(.dark)
//    }
//}


struct TopCameraControlsView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Image("maria-cappelli")
                .resizable()
//                .frame(width: 500, height: 1000)
            TopCameraControlsView(
                viewModel: TopCameraControlsViewViewModel(),
                isRecordingVideo: .constant(false),
                recordingDuration: .constant(CMTime()),
                currentAlbumName: .constant("KeyName"),
                flashMode: .constant(.on),
                closeButtonTapped: {},
                flashButtonPressed: {}
            )
            
        }
    }
}
