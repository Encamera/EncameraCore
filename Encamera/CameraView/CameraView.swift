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
        #if targetEnvironment(simulator)
//        Color.clear.background {
//            Image("kristina-flour").resizable().clipped().aspectRatio(contentMode: .fill)
//        }
        missingPermissionsView
        #else
        CameraPreview(session: cameraModel.session, modePublisher: cameraModeStateModel.$selectedMode.eraseToAnyPublisher())
            .gesture(
                MagnificationGesture()
                    .onChanged(cameraModel.handleMagnificationOnChanged)
                    .onEnded(cameraModel.handleMagnificationEnded)
            )
            .onChange(of: rotationFromOrientation, perform: { newValue in
                cameraModel.setOrientation(AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation) ?? .portrait)
            }).alert(isPresented: $cameraModel.showAlertError, content: {
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
        #endif
    }
    
    @State var showTookFirstPhotoSheet = true
    
    
    
    var body: some View {
        NavigationView {
            
            ZStack {
                settingsScreen
                keySelectionList
                galleryView
                mainCamera
                
                tutorialViews
                if cameraModel.service.model.setupResult == .notAuthorized {
                    missingPermissionsView
                }
            }
            .background(Color.background)
            .screenBlocked()
            .alert(isPresented: $cameraModel.showAlertForMissingKey) {
                Alert(title: Text(L10n.noKeySelected), message: Text(L10n.youDonTHaveAnActiveKeySelectedSelectOneToContinueSavingMedia), primaryButton: .default(Text(L10n.keySelection)) {
                    cameraModel.showingKeySelection = true
                }, secondaryButton: .cancel())
            }
            .sheet(isPresented: $cameraModel.showStoreSheet) {
                ProductStoreView()
            }
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
                FirstPhotoTakenTutorial(
                    shouldShow: $cameraModel.showTookFirstPhotoSheet
                )
            } else if cameraModel.showExplanationForUpgrade {
                ExplanationForUpgradeTutorial(
                    shouldShow: $cameraModel.showExplanationForUpgrade,
                    showUpgrade: $cameraModel.showStoreSheet)
            }
        }
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    private var galleryView: some View {
        NavigationLink(isActive: $cameraModel.showGalleryView) {
            if let key = cameraModel.keyManager.currentKey {
                GalleryGridView(viewModel: .init(privateKey: key))
            }
        } label: {
            EmptyView()
        }.isDetailLink(false)

    }
    
    private var keySelectionList: some View {
        NavigationLink(isActive: $cameraModel.showingKeySelection) {
            KeySelectionGrid(viewModel: .init(keyManager: cameraModel.keyManager, purchaseManager: cameraModel.purchaseManager, fileManager: cameraModel.fileAccess))
                
        } label: {
            EmptyView()
        }.isDetailLink(false)
        
    }

    private var settingsScreen: some View {
        NavigationLink(isActive: $cameraModel.showSettingsScreen) {
            SettingsView(viewModel: .init(keyManager: cameraModel.keyManager, fileAccess: cameraModel.fileAccess))
        } label: {
            EmptyView()
        }.isDetailLink(false)
    }
    
    
    
    private var mainCamera: some View {
        VStack {
        let currrentKeyName = Binding<String> {
            return cameraModel.keyManager.currentKey?.name ?? L10n.noKey
        } set: { _, _ in
            
        }

            TopBarView(viewModel: .init(purchaseManager: cameraModel.purchaseManager), showingKeySelection: $cameraModel.showingKeySelection, showStoreSheet: $cameraModel.showStoreSheet,
                       isRecordingVideo: $cameraModel.isRecordingVideo,
                       recordingDuration: $cameraModel.recordingDuration,
                       currentKeyName: currrentKeyName,
                       flashMode: $cameraModel.flashMode,
                       settingsButtonTapped: {
                self.cameraModel.showSettingsScreen = true
            }) {
                self.cameraModel.switchFlash()
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
                }
            }
            if FeatureToggle.isEnabled(feature: .enableVideo) {
                cameraModePicker
            }
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
    
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
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
            return .foregroundPrimary
        }
    }
}

struct CameraView_Previews: PreviewProvider {
    static var previews: some View {
        let model = CameraModel(
            keyManager: DemoKeyManager(),
            authManager: DemoAuthManager(),
            cameraService: CameraConfigurationService(model: .init()),
            fileAccess: DemoFileEnumerator(),
            storageSettingsManager: DemoStorageSettingsManager(),
            purchaseManager: DemoPurchasedPermissionManaging()
        )
        CameraView(cameraModel: model)
            .preferredColorScheme(.dark)
    }
}


