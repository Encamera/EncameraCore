//
//  MovieViewing.swift
//  Encamera
//
//  Created by Alexander Freas on 22.11.21.
//

import SwiftUI
import AVKit
import Combine
import EncameraCore

class MovieViewingViewModel: ObservableObject, MediaViewingViewModel {
    var fileAccess: FileAccess?
    
    @Published var decryptedFileRef: InteractableMedia<CleartextMedia>?
    @MainActor
    @Published var decryptProgress: FileLoadingStatus = .notLoaded
    @Published var player: AVPlayer?
    @Published fileprivate var didFinishPlaying: Bool = false
    @Published fileprivate var videoDuration: Double = 0.0
    @Published var isExpanded: Bool = true
    fileprivate var cancellables = Set<AnyCancellable>()


    var error: MediaViewingError?
    
    
    var sourceMedia: InteractableMedia<EncryptedMedia>
    var delegate: MediaViewingDelegate

    required init(media: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, delegate: MediaViewingDelegate) {
        self.sourceMedia = media
        self.fileAccess = fileAccess
        self.delegate = delegate
        
        NotificationUtils.didEnterBackgroundPublisher.sink { _ in
            self.player?.pause()
        }.store(in: &cancellables)
    }
    
    func seek(to position: Double) {
        let time = CMTime(seconds: position, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func setupVideoObserver(updateHandler: @escaping (Double) -> Void) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let mainQueue = DispatchQueue.main
        player?.addPeriodicTimeObserver(forInterval: interval, queue: mainQueue) {  time in
            let currentTime = CMTimeGetSeconds(time)
            updateHandler(currentTime)
        }
    }

    private var durationObservation: NSKeyValueObservation?

    @MainActor
    func decrypt() async throws -> InteractableMedia<CleartextMedia> {
        guard let fileAccess = fileAccess else {
            debugPrint("File access not available")
            throw MediaViewingError.fileAccessNotAvailable
        }
        let cleartextMedia = try await fileAccess.loadMedia(media: sourceMedia) { progress in
            debugPrint("Decrypting movie: \(progress)")
            self.decryptProgress = progress
        }

        guard let url = cleartextMedia.videoURL else {
            throw MediaViewingError.decryptError(wrapped: NSError(domain: "No URL", code: 0, userInfo: nil))
        }

        // Initialize the AVPlayer when the media is decrypted
        let player = AVPlayer(url: url)
        NotificationCenter.default
            .addObserver(self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
        self.player = player
        // Observe changes in the duration property
        durationObservation = self.player?.currentItem?.observe(\.duration, options: [.new]) { [weak self] _, change in
            guard let self = self else { return }
            if let newDuration = change.newValue {
                let durationSeconds = newDuration.seconds
                if !durationSeconds.isNaN {
                    self.videoDuration = durationSeconds
                }
            }
        }
        do {
            let _ = try await fileAccess.createPreview(for: cleartextMedia)
        } catch {
            debugPrint("Could not create preview for movie")
        }
        
        return cleartextMedia
        
    }
    
    func playVideo() {
        player?.play()
    }
    
    func pauseVideo() {
        player?.pause()
    }
    
    @objc func playerDidFinishPlaying() {
        print("did finish playing")
        player?.seek(to: .zero)
        didFinishPlaying = true
    }
    
    func decryptAndSet() async {
        guard await decryptedFileRef == nil else {
            debugPrint("decryptAndSet: not decrypting because we already have a ref")
            return
        }
        do {
            let decrypted = try await decrypt()
            await MainActor.run {
                decryptedFileRef = decrypted
                delegate.didView(media: sourceMedia)
            }

        } catch {

            self.error = .decryptError(wrapped: error)
        }
    }
}

struct MovieViewing: View {
    @State var progress = 0.0
    @StateObject var viewModel: MovieViewingViewModel
    @State private var videoPosition: Double = 0
    @Binding var isPlayingVideo: Bool
    
    private func videoPositionBinding() -> Binding<Double> {
        Binding(
            get: { self.videoPosition },
            set: { newPosition in
                videoPosition = newPosition
                viewModel.seek(to: newPosition)
            }
        )
    }
    var body: some View {
        VStack {
            
            if viewModel.decryptedFileRef?.videoURL != nil {
                AVPlayerLayerRepresentable(player: viewModel.player, isExpanded: viewModel.isExpanded)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                if viewModel.videoDuration > 0 {
                    VideoScrubbingSlider(value: videoPositionBinding(), isPlayingVideo: $isPlayingVideo, isExpanded: $viewModel.isExpanded, range: 0...viewModel.videoDuration)
                        .padding()
                        .onTapGesture {
                            viewModel.player?.pause()
                        }
                        .onAppear {
                            viewModel.setupVideoObserver { position in
                                videoPosition = position
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: 60.0)
                }

            } else if let error = viewModel.error {
                Text(L10n.movieDecryptionError(error.localizedDescription))
                    .foregroundColor(.red)
            } else {
                progressView
            }
        }
        .clipped()
        .onChange(of: isPlayingVideo) { newValue in
            if newValue == true {
                viewModel.playVideo()
            } else {
                viewModel.pauseVideo()
            }
        }
        .onChange(of: viewModel.didFinishPlaying) { newValue in
            if newValue == true {
                viewModel.player?.pause()
            }
            isPlayingVideo = !newValue
        }
        .onDisappear {
            isPlayingVideo = false
            viewModel.player?.pause()
        }

    }

    private var progressView: some View {
        ProgressView(statusString, value: progress)
            .onReceive(viewModel.$decryptProgress) { out in
            switch out {
            case .downloading(progress: let progress),
                    .decrypting(progress: let progress):
                self.progress = progress
            case .loaded:
                self.progress = 1.0
            default:
                break
            }
        }.task {
            await viewModel.decryptAndSet()
            EventTracking.trackMovieViewed()
        }.padding()
    }

    private var statusString: String {
        switch viewModel.decryptProgress {
        case .notLoaded:
            return L10n.decrypting
        case .downloading(progress: _):
            return L10n.importingPleaseWait
        case .loaded:
            return ""
        case .decrypting(progress: _):
            return L10n.decrypting
        }
    }
}
//
//struct MovieViewing_Previews: PreviewProvider {
//    static var previews: some View {
//        MovieViewing<InteractableMedia<EncryptedMedia>>(progress: 20.0, viewModel: .init(media: InteractableMedia<EncryptedMedia>(source: URL(fileURLWithPath: ""),
//                                                                            mediaType: .video,
//                                                                            id: "234"),
//                                                      fileAccess: DemoFileEnumerator()))
//    }
//}
