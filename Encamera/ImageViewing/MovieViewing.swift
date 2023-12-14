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

class MovieViewingViewModel<SourceType: MediaDescribing>: ObservableObject, MediaViewingViewModel {
    var fileAccess: FileAccess?
    
    @Published var decryptedFileRef: CleartextMedia<URL>?
    @MainActor
    @Published var decryptProgress: Double = 0.0
    @Published var player: AVPlayer?
    @Published fileprivate var didFinishPlaying: Bool = false
    @Published fileprivate var videoDuration: Double = 0.0
    @Published var isExpanded: Bool = true
    fileprivate var cancellables = Set<AnyCancellable>()


    var error: MediaViewingError?
    
    
    var sourceMedia: SourceType
    

    required init(media: SourceType, fileAccess: FileAccess) {
        self.sourceMedia = media
        self.fileAccess = fileAccess
        
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
    func decrypt() async throws -> CleartextMedia<URL> {
        guard let fileAccess = fileAccess else {
            throw MediaViewingError.fileAccessNotAvailable
        }
        let cleartextMedia = try await fileAccess.loadMediaToURL(media: sourceMedia) { progress in
            self.decryptProgress = progress
        }
        
        // Initialize the AVPlayer when the media is decrypted
        let player = AVPlayer(url: cleartextMedia.source)
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
    
}

struct MovieViewing<M: MediaDescribing>: View where M.MediaSource == URL {
    @State var progress = 0.0
    @StateObject var viewModel: MovieViewingViewModel<M>
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
            
            if viewModel.decryptedFileRef?.source != nil {
                AVPlayerLayerRepresentable(player: viewModel.player, isExpanded: viewModel.isExpanded)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text(L10n.couldNotDecryptMovie(error.localizedDescription))
                    .foregroundColor(.red)
            } else {
                ProgressView(L10n.decrypting, value: progress).onReceive(viewModel.$decryptProgress) { out in
                    self.progress = out
                }.task {
                    await viewModel.decryptAndSet()
                    EventTracking.trackMovieViewed()
                }.padding()
                
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
}
//
//struct MovieViewing_Previews: PreviewProvider {
//    static var previews: some View {
//        MovieViewing<EncryptedMedia>(progress: 20.0, viewModel: .init(media: EncryptedMedia(source: URL(fileURLWithPath: ""),
//                                                                            mediaType: .video,
//                                                                            id: "234"),
//                                                      fileAccess: DemoFileEnumerator()))
//    }
//}
