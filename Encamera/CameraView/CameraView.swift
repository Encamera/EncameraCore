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

    private let viewTitle: String = "Camera"

    private var cameraPreview: some View {
#if targetEnvironment(simulator)
        Color.clear
//        missingPermissionsView
#else
        CameraPreview(modePublisher: cameraModeStateModel.$selectedMode.eraseToAnyPublisher(),
                      capturePublisher: cameraModel.captureActionPublisher,
            session: cameraModel.session
        )
        .onReceive(cameraModeStateModel.$selectedMode, perform: { value in
            self.cameraModel.selectedCameraMode = value
        })
        .onChange(of: rotationFromOrientation, { oldValue, newValue in
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
#endif
    }

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
        .alert(isPresented: $cameraModel.showAlertForMissingAlbum) {
            Alert(title: Text(L10n.noAlbum), message: Text(L10n.noAlbumSelected), dismissButton: .default(Text(L10n.ok)) {
                cameraModel.showingAlbum = true
            })

        }
        .productStore(isPresented: $cameraModel.showPurchaseSheet, fromViewName: viewTitle) { finishedAction in
            if case .purchaseComplete = finishedAction {
                cameraModel.showExplanationForUpgrade = false
            }
            Task {
                await cameraModel.service.start()
            }
        }
    }

    @ViewBuilder private var missingPermissionsView: some View {
        Color.clear.background {

            VStack {
                Group {
                    Text(L10n.missingCameraAccess)
                        .fontType(.pt14)
                    Button {
                        openSettings()
                    } label: {
                        Text(L10n.openSystemSettings)
                    }.textPill(color: .actionYellowGreen)
                    .fontType(.pt14, on: .primaryButton)
                }
            }

            .padding()
        }
    }

    @ViewBuilder private var tutorialViews: some View {
        Group {
        }
        .photoLimitReachedModal(isPresented: $cameraModel.showExplanationForUpgrade) {
            EventTracking.trackPhotoLimitReachedScreenUpgradeTapped(from: trackingViewName)
            cameraModel.showPurchaseSheet = true
        } onSecondaryButtonPressed: {
            EventTracking.trackPhotoLimitReachedScreenDismissed(from: trackingViewName)
            cameraModel.showExplanationForUpgrade = false
        }
        .chooseStorageModal(isPresented: $cameraModel.showChooseStorageSheet, album: cameraModel.albumManager.currentAlbum, purchasedPermissions: cameraModel.purchaseManager, didSelectStorage: { selectedStorage, hasEntitlement in
            if hasEntitlement || selectedStorage == .local {
                afterChooseStorageAction()
                guard let currentAlbum = cameraModel.albumManager.currentAlbum else {
                    debugPrint("Current album is not set")
                    return
                }
                EventTracking.trackConfirmStorageTypeSelected(type: selectedStorage)
                cameraModel.albumManager.currentAlbum = try? cameraModel.albumManager.moveAlbum(album: currentAlbum, toStorage: selectedStorage)
                
            } else if !hasEntitlement && selectedStorage == .icloud {
                cameraModel.showPurchaseSheet = true
            }
        }, dismissAction: afterChooseStorageAction)
    }

    private func afterChooseStorageAction() {
        cameraModel.showChooseStorageSheet = false
        cameraModel.showSavedToAlbumTooltip = true
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
        ).opacity(cameraModel.showSavedToAlbumTooltip ? 1 : 0)
    }
    private var mainCamera: some View {
        ZStack {


            cameraPreview
                .frame(maxHeight: .infinity)

            VStack {
                TopCameraControlsView(viewModel: .init(albumManager: cameraModel.albumManager,
                                                       mode: cameraModel.$selectedCameraMode,
                                                       canCaptureLivePhoto: cameraModel.canCaptureLivePhoto),
                                      isRecordingVideo: $cameraModel.isRecordingVideo,
                                      recordingDuration: $cameraModel.recordingDuration,
                                      showSavedToAlbumTooltip: $cameraModel.showSavedToAlbumTooltip,
                                      flashMode:  $cameraModel.flashMode,
                                      isLivePhotoEnabled: $cameraModel.isLivePhotoEnabled,
                                      closeButtonTapped: closeCamera,
                                      flashButtonPressed: {
                                          self.cameraModel.switchFlash()
                                      })
                tooltip
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
                Spacer()
                if cameraModel.selectedCameraMode == .video &&  AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    VStack {
                        Spacer()
                        Button("\(Image(systemName: "mic.slash.fill")) \(L10n.openSettings)") {
                            openSettings()
                        }
                        .primaryButton()
                        .padding()
                    }
                } else if cameraModel.cameraPosition == .back {
                    VStack {
                        Spacer()
                        CameraZoomControlButtons(supportedZoomScales: cameraModel.availableZoomLevels, selectedZoomScale: $cameraModel.currentZoomFactor)
                            .frame(width: 300, height: 44)
                    }
                }
                bottomButtonPanel
                    .padding(.bottom, getSafeAreaBottom())
            }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .task {
            await cameraModel.initialConfiguration()
        }
        .onDisappear {
            debugPrint("CameraView disappeared")
            Task {
                await cameraModel.stopCamera()
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

    private func closeCamera() {
        Task {
            await cameraModel.stopCamera()
        }
        EventTracking.trackCameraClosed()
        cameraModel.closeButtonTapped(nil)
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
            albumManager: DemoAlbumManager(),
            cameraService: CameraConfigurationService(model: .init()),
            fileAccess: DemoFileEnumerator(),
            purchaseManager: DemoPurchasedPermissionManaging(),
            closeButtonTapped: {_ in}
        )
        CameraView(cameraModel: model, hasMediaToImport: .constant(false))
        .preferredColorScheme(.dark)
    }
}


