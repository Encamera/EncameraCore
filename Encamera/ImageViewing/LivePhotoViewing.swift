//
//  ImageViewing.swift
//  encamera
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Combine
import EncameraCore
import AVFoundation
import Photos


class LivePhotoViewingViewModel: ObservableObject {

    typealias MagnificationGestureType = _EndedGesture<_ChangedGesture<MagnifyGesture>>
    typealias DragGestureType = _EndedGesture<_ChangedGesture<DragGesture>>
    typealias TapGestureType = _EndedGesture<TapGesture>
    typealias LongPressGestureType = _EndedGesture<_ChangedGesture<LongPressGesture>>

    @Published var decryptedFileRef: InteractableMedia<CleartextMedia>?
    @Published var preparedLivePhoto: PHLivePhoto?
    @Published var loadingProgress: Double = 0.0
    @Published var currentScale: CGFloat = 1.0
    @Published var finalScale: CGFloat = 1.0
    @Published var finalOffset: CGSize = .zero
    @Published var currentOffset: CGSize = .zero
    @Published var currentFrame: CGRect = .zero
    @Published var player: AVPlayer?
    @Published var showLivePhotoViewport: Bool = false

    var sourceMedia: InteractableMedia<EncryptedMedia>
    var fileAccess: FileAccess
    var error: MediaViewingError?

    private var livePhotoFinished: (() -> Void)?
    private var delegate: MediaViewingDelegate
    private var cancellables = Set<AnyCancellable>()  // Store cancellables

    init(sourceMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess, delegate: MediaViewingDelegate) {
        self.sourceMedia = sourceMedia
        self.fileAccess = fileAccess
        self.delegate = delegate
    }

    func decryptAndSet() {
        Task { [self] in
            do {
                let result = try await fileAccess.loadMedia(media: sourceMedia) { [self] progress in
                    switch progress {
                    case .decrypting(progress: let progress), .downloading(progress: let progress):
                        loadingProgress = progress
                    case .loaded:
                        loadingProgress = 1.0
                    case .notLoaded:
                        loadingProgress = 0.0
                    }
                }
                if let url = result.videoURL {
                    let player = AVPlayer(url: url)
                    NotificationCenter.default
                        .addObserver(self,
                                     selector: #selector(playerDidFinishPlaying),
                                     name: .AVPlayerItemDidPlayToEndTime,
                                     object: player.currentItem
                        )
                    self.player = player
                }

                // Subscribe to the Combine publisher for generating the live photo
                result.generateLivePhoto()
                    .receive(on: RunLoop.main)
                    .sink(receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            self.error = .decryptError(wrapped: error)
                        }
                    }, receiveValue: { livePhoto in
                        self.preparedLivePhoto = livePhoto
                        self.decryptedFileRef = result
                        self.delegate.didView(media: self.sourceMedia)
                    })
                    .store(in: &cancellables)

            } catch {
                self.error = .decryptError(wrapped: error)
            }
        }
    }

    @objc func playerDidFinishPlaying() {
        print("did finish playing")
        withAnimation {
            showLivePhotoViewport = false
        }
        player?.seek(to: .zero)
        livePhotoFinished?()
    }

    func resetViewState() {
        withAnimation {
            finalScale = 1.0
            currentScale = 1.0
            finalOffset = .zero
            currentOffset = .zero
        }
    }

    var offset: CGSize {
        return CGSize(
            width: finalOffset.width + currentOffset.width,
            height: finalOffset.height + currentOffset.height
        )
    }

    private func didResetViewStateIfNeeded(targetScale: CGFloat, targetOffset: CGSize) -> Bool {
        debugPrint("didResetViewStateIfNeeded: targetScale: \(targetScale), targetOffset: \(targetOffset)")

        if targetScale <= 1.0 {
            resetViewState()
            return true
        }
        return false
    }

    var dragGesture: DragGestureType {

        DragGesture(minimumDistance: 1).onChanged({ [self] value in

            if finalScale > 1.0 {
                currentOffset = value.translation
            }

        }).onEnded({ [self] value in
            if finalScale <= 1.0 {
                resetViewState()
            } else {
                let nextOffset: CGSize = .init(
                    width: finalOffset.width + currentOffset.width,
                    height: finalOffset.height + currentOffset.height)
                if didResetViewStateIfNeeded(targetScale: finalScale, targetOffset: nextOffset) {
                    return
                }
                debugPrint("nextOffset: \(abs(nextOffset.width)), currentFrame: \(currentFrame.width / 2)")
                if abs(nextOffset.width) < currentFrame.width / 2 && abs(nextOffset.height) < currentFrame.height {
                    finalOffset = nextOffset

                }
                currentOffset = .zero
            }

        })
    }

    var magnificationGesture: MagnificationGestureType {
        MagnifyGesture().onChanged({ [self] value in
            currentScale = value.magnification
        })
        .onEnded({ [self] amount in
            let final = finalScale * currentScale

            if didResetViewStateIfNeeded(targetScale: final, targetOffset: currentOffset) {
                return
            }
            finalScale = final < 1.0 ? 1.0 : final
            currentScale = 1.0
        })
    }

    var tapGesture: TapGestureType {
        TapGesture(count: 2).onEnded { [self] in
            withAnimation { [self] in

                self.finalScale = self.finalScale > 1.0 ? 1.0 : 3.0
                self.finalOffset = .zero
            }
        }
    }
}

struct LivePhotoViewing: View {

    @State var showBottomActions = false
    @StateObject var viewModel: LivePhotoViewingViewModel

    var externalGesture: DragGesture

    private func calculateScaleAnchor() -> UnitPoint {
        let frame = viewModel.currentFrame
        let offset = viewModel.offset

        // Calculate the center point of the currently visible area
        let visibleCenterX = frame.midX - offset.width
        let visibleCenterY = frame.midY - offset.height

        // Normalize these values to a range of 0 to 1
        let normalizedX = visibleCenterX / frame.width
        let normalizedY = visibleCenterY / frame.height

        // Ensure the values are within the 0 to 1 range
        return UnitPoint(
            x: max(0, min(1, normalizedX)),
            y: max(0, min(1, normalizedY))
        )
    }


    var body: some View {

        ZStack {

            if let imageData = viewModel.preparedLivePhoto {
                LivePhotoView(livePhoto: imageData, playbackStyle: .hint)
                    .scaleEffect(viewModel.finalScale * viewModel.currentScale, anchor:
                                    calculateScaleAnchor())
                    .offset(viewModel.offset)
                    .if(viewModel.finalScale > 1.0, transform: { view in
                        view.gesture(viewModel.dragGesture)
                    })
                    .simultaneousGesture(viewModel.magnificationGesture)
                    .simultaneousGesture(viewModel.tapGesture)
                    .background(geometryReader)
                
            } else if let error = viewModel.error {
                DecryptErrorExplanation(error: error)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            viewModel.decryptAndSet()
            EventTracking.trackImageViewed()
        }
        .onDisappear {
            viewModel.finalScale = 1.0
            viewModel.finalOffset = .zero
        }
        .navigationBarTitleDisplayMode(.inline)
    }


    var geometryReader: some View {
        GeometryReader { geometry in
            Color.clear
                .preference(key: FramePreferenceKey.self, value: geometry.frame(in: .global))
        }
        .onPreferenceChange(FramePreferenceKey.self) { value in
            viewModel.currentFrame = value
        }
    }
}
