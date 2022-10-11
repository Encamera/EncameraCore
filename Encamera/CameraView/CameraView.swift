import SwiftUI
import Combine
import AVFoundation


struct CameraView: View {
    
    private enum Constants {
        static var minCaptureButtonEdge: Double = 80
        static var innerCaptureButtonLineWidth: Double = 2
        static var innerCaptureButtonStroke: Double = 0.8
        static var innerCaptureButtonSize = Constants.minCaptureButtonEdge * 0.8
    }
    
    @StateObject var cameraModel: CameraModel
    @State var cameraModeStateModel = CameraModeStateModel()
    @GestureState var magnificationGesture = false

    @Environment(\.rotationFromOrientation) var rotationFromOrientation

    
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
    
    private var bottomButtonPanel: some View {
        VStack {
            HStack {
                capturedPhotoThumbnail
                
                captureButton
                    .frame(maxWidth: .infinity)
                    .padding()
                flipCameraButton
            }
            .padding(.horizontal, 20)
        }
    }
    private var cameraPreview: some View {
        GeometryReader { reader in
            CameraPreview(session: cameraModel.session, modePublisher: cameraModeStateModel.$selectedMode.eraseToAnyPublisher())
                .gesture(
                    MagnificationGesture()
                        .onChanged(cameraModel.handleMagnificationOnChanged)
                        .onEnded(cameraModel.handleMagnificationEnded)
                )
                .onChange(of: rotationFromOrientation, perform: { newValue in
                    Task {
                        cameraModel.service.model.orientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation) ?? .portrait
                    }
                })
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
                .animation(.easeInOut, value: cameraModel.willCapturePhoto)
        }
    }
    
    private var topBar: some View {
        ZStack {
            HStack {
                
                Button {
                    cameraModel.showingKeySelection = true
                } label: {
                    Image(systemName: "key.fill")
                        .frame(width: 44, height: 44)
                        .symbolRenderingMode(.monochrome)

                }
                .rotateForOrientation()
                Text(cameraModel.keyManager.currentKey?.name ?? "No Key")
                    .fontType(.small)
                                    Spacer()
                Button(action: {
                    cameraModel.switchFlash()
                }, label: {
                    Image(systemName: cameraModel.flashMode.systemIconForMode)
                        .foregroundColor(cameraModel.flashMode.colorForMode)
                        .frame(width: 44, height: 44)
                    
                })
                .rotateForOrientation()
                
                
            }
            .tint(.white)
                        if cameraModel.isRecordingVideo {
                Text("\(cameraModel.recordingDuration.durationText)")
                    .fontType(.small)
                    .padding(5)
                    .background(Color.videoRecordingIndicator)
                    .cornerRadius(10)
                                }
        }
    }
    
    var body: some View {
        NavigationView {
            
            ZStack {
                NavigationLink(isActive: $cameraModel.showingKeySelection) {
                    KeySelectionList(viewModel: .init(keyManager: cameraModel.keyManager))
                        .toolbar {
                            NavigationLink {
        
                                SettingsView(viewModel: .init(keyManager: cameraModel.keyManager, fileAccess: cameraModel.fileAccess))
                            } label: {
                                Image(systemName: "gear")
                            }
                            .isDetailLink(false)
                            }
                } label: {
                    EmptyView()
                }.isDetailLink(false)
                NavigationLink(isActive: $cameraModel.showGalleryView) {
                    if let key = cameraModel.keyManager.currentKey {
                        GalleryGridView(viewModel: .init(privateKey: key))
                    }
                } label: {
                    EmptyView()
                }.isDetailLink(false)
                
                
                VStack {
                    topBar
                    cameraPreview
                        .edgesIgnoringSafeArea(.all)
                    bottomButtonPanel
                }
                .onChange(of: cameraModel.authManager.isAuthenticated, perform: { newValue in
                    guard newValue == true else {
                        return
                    }
                    Task {
                        await cameraModel.service.checkForPermissions()
                        await cameraModel.service.configure()
                    }
                })
                
                .navigationBarHidden(true)
                .navigationTitle("")
            }
            .background(Color.background)
            .screenBlocked()
            .alert(isPresented: $cameraModel.showAlertForMissingKey) {
                
                Alert(title: Text("No key selected"), message: Text("You don't have an active key selected, select one to continue saving media."), primaryButton: .default(Text("Key Selection")) {
                    cameraModel.showingKeySelection = true
                }, secondaryButton: .cancel())
            }
        }

    }
}

private extension CameraView {
    
    var cameraModePicker: some View {
        CameraModePicker(pressedAction: { mode in
        })
        .onReceive(cameraModeStateModel.$selectedMode) { newValue in
            cameraModel.selectedCameraMode = newValue
        }
        .environmentObject(cameraModeStateModel)
        
    }
    
}

private extension AVCaptureDevice.FlashMode {
    
    var systemIconForMode: String {
        switch self {
        case .auto:
            return "bolt.badge.a.fill"
        case .on:
            return "bolt.fill"
        case .off:
            return "bolt.slash.fill"
        default:
            return "bolt"
        }
    }
    
    var colorForMode: Color {
        switch self {
        case .auto, .on:
            return .yellow
        default:
            return .foregroundPrimary
        }
    }
}

struct CameraView_Previews: PreviewProvider {
    static var previews: some View {
        CameraView(cameraModel: CameraModel(keyManager: DemoKeyManager(), authManager: DemoAuthManager(), cameraService: CameraConfigurationService(model: .init()), fileAccess: DemoFileEnumerator(), storageSettingsManager: DemoStorageSettingsManager()))
        
    }
}


