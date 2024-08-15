import SwiftUI
import PhotosUI
import Photos

struct LivePhotoView: UIViewRepresentable {
    var livePhoto: PHLivePhoto?
    var isMuted: Bool = false
    var playbackStyle: PHLivePhotoViewPlaybackStyle = .full

    // Make UIView type
    func makeUIView(context: Context) -> PHLivePhotoView {
        let livePhotoView = PHLivePhotoView()
        livePhotoView.livePhoto = livePhoto
        livePhotoView.isMuted = isMuted
        livePhotoView.contentMode = .scaleAspectFit // Ensure the Live Photo fits within the frame
        return livePhotoView
    }

    // Update UIView with new values
    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        uiView.livePhoto = livePhoto
        uiView.isMuted = isMuted
        // Start playback if a live photo is set
        if let _ = livePhoto {
            uiView.startPlayback(with: playbackStyle)
        }
    }

    // Coordinator class for delegate and other coordination
    class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var parent: LivePhotoView

        init(parent: LivePhotoView) {
            self.parent = parent
        }

        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            // Handle playback end if needed
        }
    }

    // Make coordinator for SwiftUI to interact with delegate
    func makeCoordinator() -> Coordinator {
        return Coordinator(parent: self)
    }
}

struct LivePhotoView_Previews: PreviewProvider {
    static var previews: some View {
        LivePhotoView(livePhoto: nil) // Placeholder for preview
            .frame(width: 300, height: 300)
    }
}
