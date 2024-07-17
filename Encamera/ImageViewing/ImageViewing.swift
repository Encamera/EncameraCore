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

enum MediaViewingError: ErrorDescribable {
    case noKeyAvailable
    case fileAccessNotAvailable
    case decryptError(wrapped: Error)

    var displayDescription: String {
        switch self {
        case .noKeyAvailable:
            return L10n.noKeyAvailable
        case .fileAccessNotAvailable:
            return L10n.noFileAccessAvailable
        case .decryptError(let wrapped as ErrorDescribable):
            return L10n.decryptionError(wrapped.displayDescription)
        case .decryptError(wrapped: let wrapped):
            return L10n.decryptionError(wrapped.localizedDescription)
        }
    }
}

protocol MediaViewingViewModel: AnyObject {

    associatedtype SourceType: EncryptedMedia

    var sourceMedia: InteractableMedia<SourceType> { get set }
    var fileAccess: FileAccess? { get set }
    var error: MediaViewingError? { get set }

    @MainActor
    var decryptedFileRef: InteractableMedia<CleartextMedia>? { get set }
    init(media: InteractableMedia<SourceType>, fileAccess: FileAccess)

    func decrypt() async throws -> InteractableMedia<CleartextMedia>
}

extension MediaViewingViewModel {
    func decryptAndSet() async {
        guard await decryptedFileRef == nil else {
            debugPrint("decryptAndSet: not decrypting because we already have a ref")
            return
        }
        do {
            let decrypted = try await decrypt()
            await MainActor.run {
                decryptedFileRef = decrypted
            }

        } catch {

            self.error = .decryptError(wrapped: error)
        }
    }

}

class ImageViewingViewModel: ObservableObject {

    typealias MagnificationGestureType = _EndedGesture<_ChangedGesture<MagnifyGesture>>
    typealias DragGestureType = _EndedGesture<_ChangedGesture<DragGesture>>
    typealias TapGestureType = _EndedGesture<TapGesture>
    typealias LongPressGestureType = _EndedGesture<_ChangedGesture<LongPressGesture>>

    @Published var decryptedFileRef: InteractableMedia<CleartextMedia>?
    @Published var loadingProgress: Double = 0.0
    @Published var currentScale: CGFloat = 1.0
    @Published var finalScale: CGFloat = 1.0
    @Published var finalOffset: CGSize = .zero
    @Published var currentOffset: CGSize = .zero
    @Published var currentFrame: CGRect = .zero
    @Published var player: AVPlayer?
    @Published var showLivePhotoViewport: Bool = false

    var swipeLeft: (() -> Void)
    var swipeRight: (() -> Void)

    var sourceMedia: InteractableMedia<EncryptedMedia>
    var fileAccess: FileAccess
    var error: MediaViewingError?

    init(swipeLeft: @escaping ( () -> Void), swipeRight: @escaping ( () -> Void), sourceMedia: InteractableMedia<EncryptedMedia>, fileAccess: FileAccess) {
        self.swipeLeft = swipeLeft
        self.swipeRight = swipeRight
        self.sourceMedia = sourceMedia
        self.fileAccess = fileAccess
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

                await MainActor.run {
                    decryptedFileRef = result
                }

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

    func playVideo() {
        player?.play()
    }

    func pauseVideo() {
        player?.pause()
    }

    var dragGesture: DragGestureType {

        DragGesture(minimumDistance: 1).onChanged({ [self] value in

            if finalScale > 1.0 {
                currentOffset = value.translation
            }

        }).onEnded({ [self] value in
            if finalScale <= 1.0 {
                resetViewState()
                if value.location.x > value.startLocation.x {
                    swipeLeft()
                } else {
                    swipeRight()
                }
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

    var longPressGesture: LongPressGestureType {
        LongPressGesture(minimumDuration: 0.5).onChanged { [self] _ in
            withAnimation {
                showLivePhotoViewport = true
                playVideo()
            }
        }
        .onEnded { [self] _ in
            withAnimation {
//                showLivePhotoViewport = false
//                pauseVideo()
            }
        }
    }
}

struct ImageViewing: View {

    @State var showBottomActions = false
    @ObservedObject var viewModel: ImageViewingViewModel
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

            if let imageData = viewModel.decryptedFileRef?.imageData,
               let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
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
            livePhotoViewport
        }
        .simultaneousGesture(viewModel.longPressGesture)
        .onAppear {
            viewModel.decryptAndSet()
            EventTracking.trackImageViewed()
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    var livePhotoViewport: some View {
        Group {
            if viewModel.showLivePhotoViewport {
                AVPlayerLayerRepresentable(player: viewModel.player, isExpanded: true)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }                    
        .opacity(viewModel.showLivePhotoViewport ? 1 : 0)
            .animation(.easeInOut, value: viewModel.showLivePhotoViewport)
            .transition(.opacity)

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

struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
