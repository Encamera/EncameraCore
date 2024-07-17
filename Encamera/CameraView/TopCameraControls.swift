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

struct BubbleArrowShape: Shape {
    let arrowWidth: CGFloat
    let arrowHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let arrowStart = CGPoint(x: rect.midX - arrowWidth / 2, y: rect.minY)
        let arrowEnd = CGPoint(x: rect.midX + arrowWidth / 2, y: rect.minY)
        let arrowTip = CGPoint(x: rect.midX, y: rect.minY - arrowHeight)

        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))

        // Arrow
        path.addLine(to: arrowStart)
        path.addLine(to: arrowTip)
        path.addLine(to: arrowEnd)

        // Top Right Corner
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius),
                    radius: cornerRadius,
                    startAngle: Angle(degrees: -90),
                    endAngle: Angle(degrees: 0),
                    clockwise: false)

        // Bottom Right Corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
                    radius: cornerRadius,
                    startAngle: Angle(degrees: 0),
                    endAngle: Angle(degrees: 90),
                    clockwise: false)

        // Bottom Left Corner
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
                    radius: cornerRadius,
                    startAngle: Angle(degrees: 90),
                    endAngle: Angle(degrees: 180),
                    clockwise: false)

        // Top Left Corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addArc(center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius),
                    radius: cornerRadius,
                    startAngle: Angle(degrees: 180),
                    endAngle: Angle(degrees: 270),
                    clockwise: false)

        path.closeSubpath()

        return path
    }
}




class TopCameraControlsViewViewModel: ObservableObject {

    @Published var selectedAlbum: Album?

    private var cancellables = Set<AnyCancellable>()
    var albumManager: AlbumManaging
    init(albumManager: AlbumManaging) {
        self.albumManager = albumManager

        albumManager.albumOperationPublisher
            .receive(on: RunLoop.main)
            .sink { operation in
            guard case .selectedAlbumChanged(album: let album) = operation else {
                return
            }
            self.selectedAlbum = album
        }.store(in: &cancellables)
    }
}

struct TopCameraControlsView: View {

    @StateObject var viewModel: TopCameraControlsViewViewModel

    @Binding var isRecordingVideo: Bool
    @Binding var recordingDuration: CMTime
    @Binding var showSavedToAlbumTooltip: Bool
    @Binding var flashMode: AVCaptureDevice.FlashMode
    @Binding var isLivePhotoEnabled: Bool

    var closeButtonTapped: () -> ()
    var flashButtonPressed: () -> ()
    let cornerRadius = 30.0
    var body: some View {
        ZStack {
            mainControls
//            tooltip
////                .opacity(showSavedToAlbumTooltip ? 1 : 0)
//                .offset(y: 102/2 + 25)
            durationText
                .opacity(isRecordingVideo ? 1 : 0)
                .offset(y: 102/2 + 25)

        }
    }

    private var mainControls: some View {
        HStack(spacing: 0) {
            Button {
                closeButtonTapped()
            } label: {
                Image("Camera-Close")
                    .frame(width: 28, height: 28)
            }
            Spacer()
            if UserDefaultUtils.integer(forKey: .capturedPhotos) > 0 {

                Menu {

                    ForEach(Array(viewModel.albumManager.albums)) { album in
                        Button(album.name) {
                            viewModel.albumManager.currentAlbum = album
                            EventTracking.trackAlbumSelectedFromTopBar()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.albumManager.currentAlbum?.name ?? L10n.noAlbum)
                            .fontType(.pt10, on: .background)
                            .tracking(0.20)
                        Image("Camera-Album-Arrow")
                            .frame(width: 14, height: 14)
                    }
                    .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .background(Color(red: 1, green: 1, blue: 1).opacity(0.10))
                    .cornerRadius(800)

                }

            } else {
                HStack(spacing: 10) {
                    Text(L10n.takeYourFirstPicture)
                        .fontType(.pt12, on: .lightBackground, weight: .bold)
                        .tracking(0.24)
                        .foregroundColor(.black)
                }
                .padding(EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24))
                .frame(height: 36)
                .background(.white)
                .cornerRadius(40)
            }


            Spacer()

            livePhotoButton
                .frame(width: 28, height: 28)
            Spacer().frame(width: 5.0)
            flashButton
                .frame(width: 28, height: 28)
        }
        .padding(EdgeInsets(top: getSafeAreaTop() + 10, leading: 16, bottom: 16, trailing: 16))
        .background(.ultraThinMaterial)
        .frame(height: 102)
    }
    private var tooltip: some View {
        HStack(spacing: 10) {
            Text(L10n.imageSavedToAlbum)
                .fontType(.pt12, on: .lightBackground, weight: .bold)
                .tracking(0.24)
                .foregroundColor(.black)
        }
        .padding(EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24))
        .frame(height: 36)
        .background(
            BubbleArrowShape(arrowWidth: 10, arrowHeight: 5, cornerRadius: 18)
                .fill(Color.white)
        )
    }
    let size = 27.0

    private var livePhotoButton: some View {
        Button(action: {
            isLivePhotoEnabled.toggle()
        }, label: {
            Image(systemName: "livephoto")
                .resizable()
                .scaledToFit()
                .foregroundColor(isLivePhotoEnabled ? .yellow : .gray)
                .frame(width: size, height: size)
        })
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
            .fontType(.pt18)
            .padding(5)
            .background(Color.videoRecordingIndicator)
            .cornerRadius(10)
            .opacity(isRecordingVideo ? 1.0 : 0.0)

    }
}

struct TopCameraControlsView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Image("maria-cappelli")
                .resizable()
            //                .frame(width: 500, height: 1000)
            TopCameraControlsView(
                viewModel: TopCameraControlsViewViewModel(albumManager: DemoAlbumManager()),
                isRecordingVideo: .constant(true),
                recordingDuration: .constant(.zero),
                showSavedToAlbumTooltip: .constant(true),
                flashMode: .constant(.on),
                isLivePhotoEnabled: .constant(true),
                closeButtonTapped: {},
                flashButtonPressed: {}
            )

        }
    }
}
