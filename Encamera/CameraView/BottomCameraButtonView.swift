//
//  BottomCameraButtonView.swift
//  Encamera
//
//  Created by Alexander Freas on 17.10.23.
//

import SwiftUI
import EncameraCore

struct BottomCameraButtonView: View {
    private enum Constants {
        static var minCaptureButtonEdge: Double = 80
        static var innerCaptureButtonLineWidth: Double = 2
        static var innerCaptureButtonStroke: Double = 0.8
        static var innerCaptureButtonSize = Constants.minCaptureButtonEdge * 0.8
    }
    @ObservedObject var cameraModel: CameraModel
    var cameraModeStateModel: CameraModeStateModel

    var body: some View {
        VStack {

            CameraModePicker()

            HStack {
                capturedPhotoThumbnail

                captureButton
                    .frame(maxWidth: .infinity)
                    .padding()
                flipCameraButton
            }
            .padding(.horizontal, 20)
        }
        .environmentObject(cameraModeStateModel)

    }
    private var capturedPhotoThumbnail: some View {
        Group {
            if let thumbnail = cameraModel.thumbnailImage {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture {
                        cameraModel.showGalleryView = true
                    }
            } else {
                Color.clear
            }
        }
        .rotateForOrientation()
        .frame(width: 60, height: 60)

    }
    private var flipCameraButton: some View {
        Button(action: {
            cameraModel.flipCamera()
        }, label: {
            Circle()
                .foregroundColor(Color.foregroundSecondary)
                .frame(width: 60, height: 60, alignment: .center)
                .overlay(
                    Image(systemName: "camera.rotate.fill")
                        .foregroundColor(.foregroundPrimary))
        })
        .rotateForOrientation()
    }

    private var captureButton: some View {

        Button(action: {
            Task {
                try await cameraModel.captureButtonPressed()
            }
        }, label: {
            if cameraModel.isRecordingVideo {
                Circle()
                    .foregroundColor(.videoRecordingIndicator)
                    .frame(width: Constants.minCaptureButtonEdge, height: Constants.minCaptureButtonEdge, alignment: .center)
            } else {
                Circle()
                    .frame(maxWidth: Constants.minCaptureButtonEdge, maxHeight: Constants.minCaptureButtonEdge, alignment: .center)
                    .overlay(
                        Circle()
                            .stroke(Color.background, lineWidth: Constants.innerCaptureButtonLineWidth)
                            .frame(maxWidth: Constants.innerCaptureButtonSize, maxHeight: Constants.innerCaptureButtonSize, alignment: .center)
                    )
            }
        })
    }
}

#Preview {
    BottomCameraButtonView(cameraModel: CameraModel(
        keyManager: DemoKeyManager(),
        authManager: DemoAuthManager(),
        cameraService: CameraConfigurationService(model: .init()),
        fileAccess: DemoFileEnumerator(),
        storageSettingsManager: DemoStorageSettingsManager(),
        purchaseManager: DemoPurchasedPermissionManaging()
    ), cameraModeStateModel: .init())

}
