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
        static var minCaptureButtonEdge: Double = 66
        static var innerCaptureButtonLineWidth: Double = 2
        static var innerCaptureButtonStroke: Double = 0.8
        static var innerCaptureButtonSize = Constants.minCaptureButtonEdge * 0.85
        static var thumbnailSide = 50.0
        static var trailing = 24.0
    }
    @ObservedObject var cameraModel: CameraModel
    var cameraModeStateModel: CameraModeStateModel
    var closeButtonTapped: (Album?) -> Void

    var body: some View {
        VStack(spacing: 0) {

            CameraModePicker()
            ZStack {
                HStack {
                    capturedPhotoThumbnail
                    Spacer()
                    flipCameraButton
                }
                .padding(.leading, Constants.thumbnailSide)
                .padding(.trailing, Constants.trailing)
                captureButton
                    .padding(7)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(.ultraThinMaterial)
        .environmentObject(cameraModeStateModel)
        .task {
            await cameraModel.loadThumbnail()
        }


    }

    func makeBgRectangle(side: CGFloat, order: Int) -> some View {
        Rectangle()
            .foregroundColor(.clear)
            .frame(width: side, height: side)
            .background(Color(red: 0.88, green: 0.88, blue: 0.88))

            .cornerRadius(3.2)
            .shadow(color: .black.opacity(0.1), radius: 1,
                    x: CGFloat(order) * -2, y: .zero) // Adjusted the shadow
            .offset(x: -pow(CGFloat(order), 1.7), y: .zero) // Adjusted the offset
    }
    private var capturedPhotoThumbnail: some View {
        Button {
            closeButtonTapped(cameraModel.albumManager.currentAlbum)
        } label: {
            if let thumbnail = cameraModel.thumbnailImage {
                ZStack(alignment: .leading) {
                    makeBgRectangle(side: Constants.thumbnailSide*0.7, order: 3)
                    makeBgRectangle(side: Constants.thumbnailSide*0.8, order: 2)
                    Color.white.opacity(0.01)
                        .background {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .onTapGesture {
                                    cameraModel.showGalleryView = true
                                }
                        }.clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .clipped()
                        .frame(width: Constants.thumbnailSide, height: Constants.thumbnailSide)
                }

            } else {
                Color.clear
            }
        }
        .frame(width: Constants.thumbnailSide, height: Constants.thumbnailSide)

        .rotateForOrientation()

    }
    private var flipCameraButton: some View {
        Button(action: {
            cameraModel.flipCamera()
        }, label: {
            Image("Camera-Rotate")
                .foregroundColor(.foregroundPrimary)
                .frame(width: 40, height: 40, alignment: .center)
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
//
//#Preview {
//    ZStack {
//        Image("maria-cappelli")
//            .resizable()
//
//        BottomCameraButtonView(cameraModel: CameraModel(
//            keyManager: DemoKeyManager(),
//            authManager: DemoAuthManager(),
//            cameraService: CameraConfigurationService(model: .init()),
//            fileAccess: DemoFileEnumerator(),
//            storageSettingsManager: DemoStorageSettingsManager(),
//            purchaseManager: DemoPurchasedPermissionManaging()
//        ), cameraModeStateModel: .init())
//    }
//
//}
