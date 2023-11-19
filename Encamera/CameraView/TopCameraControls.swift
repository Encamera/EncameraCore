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
    var albumManager: AlbumManaging
    init(albumManager: AlbumManaging) {
        self.albumManager = albumManager
    }
}

struct TopCameraControlsView: View {
    
    @StateObject var viewModel: TopCameraControlsViewViewModel

    @Binding var isRecordingVideo: Bool
    @Binding var recordingDuration: CMTime
    @Binding var selectedAlbum: Album?

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
            Menu {
                ForEach(viewModel.albumManager.albums) { album in
                    Button(album.name) {
                        selectedAlbum = album
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedAlbum?.name ?? L10n.noKey)
                        .fontType(.pt10, on: .background)
                        .tracking(0.20)
                    Image("Camera-Album-Arrow")
                        .frame(width: 14, height: 14)
                }
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .background(Color(red: 1, green: 1, blue: 1).opacity(0.10))
                .cornerRadius(800)

            }


            Spacer()
            flashButton
                .frame(width: 28, height: 28)
        }
        
        .padding(EdgeInsets(top: getSafeAreaTop() + 10, leading: 16, bottom: 16, trailing: 16))
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
            .fontType(.pt18)
            .padding(5)
            .background(Color.videoRecordingIndicator)
            .cornerRadius(10)
            .opacity(isRecordingVideo ? 1.0 : 0.0)

    }
}

//struct TopCameraControlsView_Previews: PreviewProvider {
//    static var previews: some View {
//        TopCameraControlsView(viewModel: .init(purchaseManager: DemoPurchasedPermissionManaging()), showingAlbum: .constant(false), isRecordingVideo: .constant(false), recordingDuration: .constant(CMTime(seconds: 0, preferredTimescale: 1)), currentKeyName: .constant("DefaultKey"), flashMode: .constant(.off), settingsButtonTapped: {}, flashButtonPressed: {})
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
                viewModel: TopCameraControlsViewViewModel(albumManager: DemoAlbumManager()),
                isRecordingVideo: .constant(false),
                recordingDuration: .constant(CMTime()),
                selectedAlbum: .constant(Album(name: "Test", storageOption: .local, creationDate: Date())),
                flashMode: .constant(.on),
                closeButtonTapped: {},
                flashButtonPressed: {}
            )
            
        }
    }
}
