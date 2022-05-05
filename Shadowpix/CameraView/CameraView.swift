import SwiftUI
import Combine
import AVFoundation

struct CameraView: View {
    @StateObject private var model = CameraModel()
    @EnvironmentObject var appState: ShadowPixState
    @Binding var galleryIconTapped: Bool
    @State private var currentZoomFactor: CGFloat = 1.0
    @Binding var showingKeySelection: Bool
    
    private var captureButton: some View {
        Button(action: {
            model.capturePhoto()
        }, label: {
            Circle()
                .foregroundColor(.white)
                .frame(width: 80, height: 80, alignment: .center)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.8), lineWidth: 2)
                        .frame(width: 65, height: 65, alignment: .center)
                )
        })
    }
    
    private var capturedPhotoThumbnail: some View {
        Group {
            Image(systemName: "photo.on.rectangle.angled")
                
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundColor(.white)
                .animation(.spring())
                .onTapGesture {
                    self.galleryIconTapped = true
                }
        }.frame(width: 60, height: 60)

    }
    
    private var flipCameraButton: some View {
        Button(action: {
            model.flipCamera()
        }, label: {
            Circle()
                .foregroundColor(Color.gray.opacity(0.2))
                .frame(width: 45, height: 45, alignment: .center)
                .overlay(
                    Image(systemName: "camera.rotate.fill")
                        .foregroundColor(.white))
        })
    }
    
    private let cameraModePickerViewModel = CameraModePickerViewModel()
    
    var body: some View {
        GeometryReader { reader in
            
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                if appState.isAuthorized {
                    
                }
                VStack {
                    HStack {
                        Button {
                            showingKeySelection = true
                        } label: {
                            Image(systemName: "key.fill").frame(width: 44, height: 44)
                        }.tint(.white)
                        Text(appState.selectedKey?.name ?? "No Key")
                        Spacer()
                        Button(action: {
                            model.switchFlash()
                        }, label: {
                            Image(systemName: model.isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                                .font(.system(size: 20, weight: .medium, design: .default))
                        })
                            .accentColor(model.isFlashOn ? .yellow : .white)
                    }.padding()
                    CameraPreview(session: model.session)
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
                                    model.zoom(with: zoomFactor)
                                }
                            })
                        )
                        .onAppear {
                            model.configure()
                        }
                        .alert(isPresented: $model.showAlertError, content: {
                            Alert(title: Text(model.alertError.title), message: Text(model.alertError.message), dismissButton: .default(Text(model.alertError.primaryButtonTitle), action: {
                                model.alertError.primaryAction?()
                            }))
                        })
                        .overlay(
                            Group {
                                if model.willCapturePhoto {
                                    Color.black
                                }
                            }
                        )
                        .animation(.easeInOut)
                    
                    HStack {
                        capturedPhotoThumbnail
                        
                        Spacer()
                        
                        CameraModePicker(viewModel: cameraModePickerViewModel)
                            .environmentObject(CameraModeStateModel())
                            .onChange(of: cameraModePickerViewModel.activeItem) { newValue in
                                appState.cameraMode = newValue
                            }
                            .clipped()
                            
                        
                        Spacer()
                        
                        flipCameraButton
                        
                    }
                    .padding(.horizontal, 20)
                }
            }
            if model.showCameraView == false {
                Color.black
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        CameraView(galleryIconTapped: .constant(false), showingKeySelection: .constant(false)).environmentObject(ShadowPixState.shared)
    }
}
