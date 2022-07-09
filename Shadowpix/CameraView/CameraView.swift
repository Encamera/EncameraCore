import SwiftUI
import Combine
import AVFoundation

struct CameraView: View {
    @ObservedObject private var cameraModel: CameraModel
    @State private var currentZoomFactor: CGFloat = 1.0
    @State var cameraModeStateModel: CameraModeStateModel
    
    init(viewModel: CameraModel) {
        self.cameraModeStateModel = CameraModeStateModel()
        self.cameraModel = viewModel
    }
    
    private var captureButton: some View {
        Button(action: {
            Task {
                try await cameraModel.captureButtonPressed()
            }
        }, label: {
            if cameraModel.isRecordingVideo {
                Circle()
                    .foregroundColor(.red)
                    .frame(width: 80, height: 80, alignment: .center)
            } else {
                Circle()
                    .foregroundColor(.white)
                    .frame(width: 80, height: 80, alignment: .center)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.8), lineWidth: 2)
                            .frame(width: 65, height: 65, alignment: .center)
                    )
            }
        })
    }
    
    private func captureAction() {
        Task {
            try await cameraModel.captureButtonPressed()
        }
    }
        
    private var capturedPhotoThumbnail: some View {
        Group {
            if let thumbnail = cameraModel.thumbnailImage {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundColor(.white)
                    .onTapGesture {
                        cameraModel.showGalleryView = true
                    }
            } else {
                Color.clear
            }
        }.frame(width: 60, height: 60)

    }
    
    private var flipCameraButton: some View {
        Button(action: {
            cameraModel.flipCamera()
        }, label: {
            Circle()
                .foregroundColor(Color.gray.opacity(0.2))
                .frame(width: 60, height: 60, alignment: .center)
                .overlay(
                    Image(systemName: "camera.rotate.fill")
                        .foregroundColor(.white))
        })
    }
    
    private var bottomButtonPanel: some View {
        VStack {
            CameraModePicker(pressedAction: { mode in
            })
            .onReceive(cameraModeStateModel.$selectedMode.dropFirst()) { newValue in
                cameraModel.selectedCameraMode = newValue
            }
            .environmentObject(cameraModeStateModel)
            HStack {
                capturedPhotoThumbnail
                    
                captureButton
                    .frame(maxWidth: .infinity)
                flipCameraButton
            }
            .padding(.horizontal, 20)
        }
    }
    
    private var cameraPreview: some View {
        GeometryReader { reader in
            CameraPreview(session: cameraModel.session, modePublisher: cameraModeStateModel.$selectedMode.eraseToAnyPublisher())
                .gesture(
                    DragGesture().onChanged({ (val) in
                        //  Only accept vertical drag
                        if abs(val.translation.height) > abs(val.translation.width) {
                            //  Get the percentage of vertical screen space covered by drag
                            let percentage: CGFloat = -(val.translation.height / reader.size.height)
                            //  Calculate new zoom factor
                            let calc = currentZoomFactor + percentage
                            //  Limit zoom factor to a maximum of 5x and a minimum of 1x
                            let zoomFactor: CGFloat = min(max(calc, 1), 5)
                            //  Store the newly calculated zoom factor
                            currentZoomFactor = zoomFactor
                            //  Sets the zoom factor to the capture device session
                            cameraModel.zoom(with: zoomFactor)
                        }
                    })
                )
                .alert(isPresented: $cameraModel.showAlertError, content: {
                    Alert(title: Text(cameraModel.alertError.title), message: Text(cameraModel.alertError.message), dismissButton: .default(Text(cameraModel.alertError.primaryButtonTitle), action: {
                        cameraModel.alertError.primaryAction?()
                    }))
                })
                .overlay(
                    Group {
                        if cameraModel.willCapturePhoto {
                            Color.black
                        }
                    }
                )
                .animation(.easeInOut)
        }
    }

    private var topBar: some View {
        ZStack {
            HStack {
                
                Button {
                    cameraModel.showingKeySelection = true
                } label: {
                    Image(systemName: "key.fill").frame(width: 44, height: 44)
                }
                Text(cameraModel.keyManager.currentKey?.name ?? "No Key")
                Spacer()
                Button(action: {
                    cameraModel.switchFlash()
                }, label: {
                    Image(systemName: cameraModel.isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                        .font(.system(size: 20, weight: .medium, design: .default))
                })
                
                .accentColor(cameraModel.isFlashOn ? .yellow : .white)
            }.padding().tint(.white).foregroundColor(.white)
            if cameraModel.isRecordingVideo {
                Text("\(cameraModel.recordingDuration.durationText)")
                .padding(5)
                .background(Color.red)
                .cornerRadius(10)
                .foregroundColor(.white)
            }
        }
    }
    
    var body: some View {
        ZStack {
            cameraPreview
                .edgesIgnoringSafeArea(.all)
            VStack {
                topBar
                Spacer()
                bottomButtonPanel
            }
        }
        .background(Color.black)
        .sheet(isPresented: $cameraModel.showingKeySelection) {
            KeySelectionList(viewModel: .init(keyManager: cameraModel.keyManager))
        }.sheet(isPresented: $cameraModel.showGalleryView) {
            MediaGalleryView<DiskFileAccess<iCloudFilesDirectoryModel>>(viewModel: MediaGalleryViewModel(keyManager: cameraModel.keyManager))
        }
        .onAppear {
            Task {
                await cameraModel.service.checkForPermissions()
                await cameraModel.service.configure()
            }
            cameraModel.loadThumbnail()
        }
        if cameraModel.showCameraView == false {
            Color.black
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        CameraView(viewModel: CameraModel(keyManager: DemoKeyManager(), authManager: AuthManager(), cameraService: CameraConfigurationService(model: .init()), fileAccess: DemoFileEnumerator()))
        
    }
}

