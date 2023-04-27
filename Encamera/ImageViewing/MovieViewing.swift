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
    var isPlaying: AnyPublisher<Bool, Never>
    @MainActor
    @Published var decryptProgress: Double = 0.0
    @Published var player: AVPlayer?
    @Published fileprivate var internalIsPlaying: Bool = false
    @Published fileprivate var videoDuration: Double = 0.0
    fileprivate var cancellables = Set<AnyCancellable>()


    var error: MediaViewingError?
    
    
    var sourceMedia: SourceType
    

    required init(media: SourceType, fileAccess: FileAccess) {
        self.sourceMedia = media
        self.fileAccess = fileAccess
        self.isPlaying = Just(false).eraseToAnyPublisher()
    }
    
    convenience init(media: SourceType, fileAccess: FileAccess, isPlaying: Published<Bool>.Publisher) {
        
        self.init(media: media, fileAccess: fileAccess)
        
        self.isPlaying = isPlaying.eraseToAnyPublisher()
        self.isPlaying.sink { value in
            self.internalIsPlaying = value
        }.store(in: &cancellables)
        
    }
    
    func seek(to position: Double) {
        let time = CMTime(seconds: position, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func setupVideoObserver(updateHandler: @escaping (Double) -> Void) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let mainQueue = DispatchQueue.main
        player?.addPeriodicTimeObserver(forInterval: interval, queue: mainQueue) { [weak self] time in
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
        self.player = AVPlayer(url: cleartextMedia.source)

        // Observe changes in the duration property
        durationObservation = self.player?.currentItem?.observe(\.duration, options: [.new]) { [weak self] _, change in
            guard let self = self else { return }
            if let newDuration = change.newValue {
                let durationSeconds = newDuration.seconds
                if !durationSeconds.isNaN {
                    self.videoDuration = durationSeconds
                    print("duration", durationSeconds)
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
    
}

struct MovieViewing<M: MediaDescribing>: View where M.MediaSource == URL {
    @State var progress = 0.0
    @StateObject var viewModel: MovieViewingViewModel<M>
    @State private var videoPosition: Double = 0

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
                AVPlayerViewRepresentable(player: viewModel.player)
                    .onChange(of: viewModel.internalIsPlaying) { newValue in
                        if newValue == true {
                            viewModel.player?.play()
                        } else {
                            viewModel.player?.pause()
                        }
                    }
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if viewModel.videoDuration > 0 {
                    VideoScrubbingSlider(value: videoPositionBinding(), range: 0...viewModel.videoDuration)
                        .padding()
                        .onTapGesture {
                            viewModel.player?.pause()
                        }
                        .onAppear {
                            viewModel.setupVideoObserver { position in
                                videoPosition = position
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: 50.0)
                }

            } else if let error = viewModel.error {
                Text(L10n.couldNotDecryptMovie(error.localizedDescription))
                    .foregroundColor(.red)
            } else {
                ProgressView(L10n.decrypting, value: progress).onReceive(viewModel.$decryptProgress) { out in
                    self.progress = out
                }.task {
                    await viewModel.decryptAndSet()
                }.padding()
                
            }
        }
    }
}
//
struct MovieViewing_Previews: PreviewProvider {
    static var previews: some View {
        MovieViewing<EncryptedMedia>(progress: 20.0, viewModel: .init(media: EncryptedMedia(source: URL(fileURLWithPath: ""),
                                                                            mediaType: .video,
                                                                            id: "234"),
                                                      fileAccess: DemoFileEnumerator()))
    }
}
