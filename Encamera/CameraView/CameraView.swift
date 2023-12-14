import SwiftUI
import Combine
import AVFoundation
import EncameraCore

struct CameraView: View {
    
    private enum Constants {
        static var minCaptureButtonEdge: Double = 80
        static var innerCaptureButtonLineWidth: Double = 2
        static var innerCaptureButtonStroke: Double = 0.8
        static var innerCaptureButtonSize = Constants.minCaptureButtonEdge * 0.8
    }
    
    
    @StateObject var cameraModel: CameraModel
    @State var cameraModeStateModel = CameraModeStateModel()
    @Binding var hasMediaToImport: Bool
    @Environment(\.rotationFromOrientation) var rotationFromOrientation
    @Environment(\.dismiss) private var dismiss
    var closeButtonTapped: () -> Void
    
    
    
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
        BottomCameraButtonView(cameraModel: cameraModel, cameraModeStateModel: cameraModeStateModel)
    }
    
    private var cameraPreview: some View {
#if targetEnvironment(simulator)
        //        Color.clear.background {
        //            Image("kristina-flour").resizable().clipped().aspectRatio(contentMode: .fill)
        //        }
        missingPermissionsView
#else
        CameraPreview(session: cameraModel.session,
                      modePublisher: cameraModeStateModel.$selectedMode.eraseToAnyPublisher())
        .onReceive(cameraModeStateModel.$selectedMode, perform: { value in
            self.cameraModel.selectedCameraMode = value
        })
        .onChange(of: rotationFromOrientation, perform: { newValue in
            cameraModel.setOrientation(AVCaptureVideoOrientation(rawValue: UIDevice.current.orientation.rawValue) ?? .portrait)
        }).alert(isPresented: $cameraModel.showAlertError, content: {
            Alert(title: Text(cameraModel.alertError.title), message: Text(cameraModel.alertError.message), dismissButton: .default(Text(cameraModel.alertError.primaryButtonTitle), action: {
                cameraModel.alertError.primaryAction?()
            }))
        })
        .onDisappear {
            HardwareVolumeButtonCaptureUtils.shared.stopObservingCaptureButton()
        }
        .onAppear {
            HardwareVolumeButtonCaptureUtils.shared.setupVolumeView()
            HardwareVolumeButtonCaptureUtils.shared.startObservingCaptureButton()
        }
        .overlay(
            Group {
                if cameraModel.willCapturePhoto {
                    Color.black
                }
            }
        )
        .animation(.easeInOut, value: cameraModel.willCapturePhoto)
#endif
    }
    
    @State var showTookFirstPhotoSheet = true
    var trackingViewName = "Camera"
    var body: some View {

            ZStack {
                mainCamera
                tutorialViews
                if cameraModel.cameraSetupResult == .notAuthorized {
                    missingPermissionsView
                }
            }
            .background(Color.background)
            .screenBlocked()
            .alert(isPresented: $cameraModel.showAlertForMissingKey) {
                Alert(title: Text(L10n.noAlbum), message: Text(L10n.noAlbumSelected), primaryButton: .default(Text(L10n.keySelection)) {
                    cameraModel.showingAlbum = true
                }, secondaryButton: .cancel())
            }
            .sheet(isPresented: $cameraModel.showStoreSheet) {
                ProductStoreView(fromView: "Camera")

            }
            .sheet(isPresented: $cameraModel.showImportedMediaScreen) {
                MediaImportView(viewModel: .init(
                    privateKey: cameraModel.privateKey,
                    albumManager: cameraModel.albumManager,
                    fileAccess: cameraModel.fileAccess
                ))
            }

        
    }
    
    @ViewBuilder private var missingPermissionsView: some View {
        Color.clear.background {
            
            VStack {
                Group {
                    Text(L10n.missingCameraAccess)
                    Button {
                        openSettings()
                    } label: {
                        Text(L10n.openSettingsToAllowCameraAccessPermission)
                    }.textPill(color: .foregroundSecondary)
                    
                }
            }
            .fontType(.medium)
            .padding()
        }
    }
    
    @ViewBuilder private var tutorialViews: some View {
        Group {
            if cameraModel.showTookFirstPhotoSheet {
                let hasEntitlement = cameraModel.purchaseManager.hasEntitlement()
                ChooseStorageModal(hasEntitlement: hasEntitlement) { selectedStorage in
                    if hasEntitlement || selectedStorage == .local {
                        cameraModel.showTookFirstPhotoSheet = false
                        guard let currentAlbum = cameraModel.albumManager.currentAlbum else {
                            debugPrint("Current album is not set")
                            return
                        }
                        EventTracking.trackConfirmStorageTypeSelected(type: selectedStorage)
                        try? cameraModel.albumManager.moveAlbum(album: currentAlbum, toStorage: selectedStorage)
                    } else if !hasEntitlement && selectedStorage == .icloud {
                        cameraModel.showPurchaseSheet = true
                    }
                    
                }
            } else if cameraModel.showExplanationForUpgrade {
                Color.clear.photoLimitReachedModal(isPresented: cameraModel.showExplanationForUpgrade) {
                    EventTracking.trackPhotoLimitReachedScreenUpgradeTapped(from: trackingViewName)
                    cameraModel.showPurchaseSheet = true
                } onSecondaryButtonPressed: {
                    EventTracking.trackPhotoLimitReachedScreenDismissed(from: trackingViewName)
                    cameraModel.showExplanationForUpgrade = false
                }
            }
        }
        .sheet(isPresented: $cameraModel.showPurchaseSheet, content: {
            ProductStoreView(fromView: "CameraView") { finishedAction in
                if case .purchaseComplete = finishedAction {       
                    cameraModel.showExplanationForUpgrade = false
                }
                Task {
                    await cameraModel.service.start()
                }
            }
        })
    }
    
    private var mainCamera: some View {
        VStack {
            TopCameraControlsView(viewModel: .init(albumManager: cameraModel.albumManager), isRecordingVideo: $cameraModel.isRecordingVideo,
                                  recordingDuration: $cameraModel.recordingDuration, flashMode:  $cameraModel.flashMode, closeButtonTapped: {
                Task {
                    await cameraModel.stopCamera()
                }
                closeButtonTapped()
            }, flashButtonPressed: {
                self.cameraModel.switchFlash()
            })
            if hasMediaToImport {
                HStack {
                    Text(L10n.finishImportingMedia)
                        .fontType(.pt24, on: .darkBackground)
                }.frame(maxWidth: .infinity)
                    .background(Color.green)
                    .onTapGesture {
                        cameraModel.showImportedMediaScreen = true
                    }
            }
            ZStack {
                cameraPreview
                    .edgesIgnoringSafeArea(.all)
                if cameraModel.selectedCameraMode == .video &&  AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    VStack {
                        Spacer()
                        Button("\(Image(systemName: "mic.slash.fill")) \(L10n.openSettings)") {
                            openSettings()
                        }.primaryButton()
                    }
                } else if cameraModel.cameraPosition == .back {
                    VStack {
                        Spacer()
                        CameraZoomControlButtons(supportedZoomScales: cameraModel.availableZoomLevels, selectedZoomScale: $cameraModel.currentZoomFactor)
                            .frame(width: 300, height: 44)
                    }
                }
                
            }
            
            
            bottomButtonPanel
        }
        .edgesIgnoringSafeArea(.top)
        .task {
            Task {
                await cameraModel.initialConfiguration()
            }
        }
        .navigationBarHidden(true)
        .navigationTitle("")
        
    }
    
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }
}

extension AVCaptureDevice.FlashMode {
    
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
            return .white
        }
    }
}
//
struct CameraView_Previews: PreviewProvider {
    static var previews: some View {
        let model = CameraModel(
            privateKey: DemoPrivateKey.dummyKey(),
            albumManager: DemoAlbumManager(),
            cameraService: CameraConfigurationService(model: .init()),
            fileAccess: DemoFileEnumerator(),
            purchaseManager: DemoPurchasedPermissionManaging()
        )
        CameraView(cameraModel: model, hasMediaToImport: .constant(false), closeButtonTapped: {
            
        })
        .preferredColorScheme(.dark)
    }
}


