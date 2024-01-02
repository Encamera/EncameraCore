//
//  ImageViewing.swift
//  encamera
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Combine
import EncameraCore

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
    
    associatedtype SourceType = MediaDescribing
    associatedtype TargetT: MediaSourcing
    
    var sourceMedia: SourceType { get set }
    var fileAccess: FileAccess? { get set }
    var error: MediaViewingError? { get set }
    
    @MainActor
    var decryptedFileRef: CleartextMedia<TargetT>? { get set }
    init(media: SourceType, fileAccess: FileAccess)
    
    func decrypt() async throws -> CleartextMedia<TargetT>
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
                self.decryptedFileRef = decrypted
            }
            
        } catch {
            
            self.error = .decryptError(wrapped: error)
        }
    }
    
}

class ImageViewingViewModel<SourceType: MediaDescribing>: ObservableObject {
    typealias MagnificationGestureType = _EndedGesture<_ChangedGesture<MagnifyGesture>>
    typealias DragGestureType = _EndedGesture<_ChangedGesture<DragGesture>>
    typealias TapGestureType = _EndedGesture<TapGesture>

    @Published var decryptedFileRef: CleartextMedia<Data>?
    @Published var loadingProgress: Double = 0.0
    @Published var currentScale: CGFloat = 1.0
    @Published var finalScale: CGFloat = 1.0
    @Published var finalOffset: CGSize = .zero
    @Published var currentOffset: CGSize = .zero
    @Published var areGesturesEnabled: Bool
    @Published var currentFrame: CGRect = .zero
    var swipeLeft: (() -> Void)
    var swipeRight: (() -> Void)

    var sourceMedia: SourceType
    var fileAccess: FileAccess
    var error: MediaViewingError?
    
    init(areGesturesEnabled: Bool, swipeLeft: @escaping ( () -> Void), swipeRight: @escaping ( () -> Void), sourceMedia: SourceType, fileAccess: FileAccess) {
        self.areGesturesEnabled = areGesturesEnabled
        self.swipeLeft = swipeLeft
        self.swipeRight = swipeRight
        self.sourceMedia = sourceMedia
        self.fileAccess = fileAccess
    }

    func decryptAndSet() {
        Task {
            do {
                let result = try await fileAccess.loadMediaInMemory(media: sourceMedia) { progress in
                    switch progress {
                    case .decrypting(progress: let progress), .downloading(progress: let progress):
                        self.loadingProgress = progress
                    case .loaded:
                        self.loadingProgress = 1.0
                    case .notLoaded:
                        self.loadingProgress = 0.0
                    }
                }
                await MainActor.run {
                    self.decryptedFileRef = result
                }
                
            } catch {
                self.error = .decryptError(wrapped: error)
            }
        }
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

        if targetScale <= 1.0 && targetOffset != .zero {
            resetViewState()
            return true
        }
        return false
    }

    var dragGesture: DragGestureType {

        DragGesture(minimumDistance: 0).onChanged({ [self] value in
            guard self.areGesturesEnabled == true else {
                return
            }
            if self.finalScale > 1.0 {
                var newOffset = value.translation
                if newOffset.height > currentFrame.height * self.finalScale {
                    newOffset.height = currentFrame.height * finalScale
                }
                currentOffset = newOffset
            }

        }).onEnded({ [self] value in
                        if self.finalScale <= 1.0 {
                self.resetViewState()
                if value.location.x > value.startLocation.x {
                    self.swipeLeft()
                } else {
                    self.swipeRight()
                }
            } else {
                let nextOffset: CGSize = .init(
                    width: self.finalOffset.width + self.currentOffset.width,
                    height: finalOffset.height + currentOffset.height)
                if self.didResetViewStateIfNeeded(targetScale: finalScale, targetOffset: nextOffset) {
                    return
                }

                self.finalOffset = nextOffset
                currentOffset = .zero
            }

        })
    }
    var magnificationGesture: MagnificationGestureType {
        MagnifyGesture().onChanged({ value in
            self.currentScale = value.magnification
        })
        .onEnded({ amount in
            let final = self.finalScale * self.currentScale

            if self.didResetViewStateIfNeeded(targetScale: final, targetOffset: self.currentOffset) {
                return
            }
            self.finalScale = final < 1.0 ? 1.0 : final
            self.currentScale = 1.0
        })
    }

    var tapGesture: TapGestureType {
        TapGesture(count: 2).onEnded {
            self.finalScale = self.finalScale > 1.0 ? 1.0 : 3.0
            self.finalOffset = .zero
        }
    }
}

struct ImageViewing<M: MediaDescribing>: View {

    @State var showBottomActions = false
    @StateObject var viewModel: ImageViewingViewModel<M>
    var externalGesture: DragGesture

    var body: some View {
        
        ZStack {
            if let imageData = viewModel.decryptedFileRef?.source,
               let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(viewModel.finalScale * viewModel.currentScale)
                    .offset(
                        x: viewModel.finalOffset.width + viewModel.currentOffset.width,
                        y: viewModel.finalOffset.height + viewModel.currentOffset.height
                    )
                    .animation(.easeInOut, value: viewModel.currentScale)
                    .animation(.easeInOut, value: viewModel.finalOffset)
                    .zIndex(1)

                    .gesture(viewModel.dragGesture)
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
        .navigationBarTitleDisplayMode(.inline)
    }



    var geometryReader: some View {
            GeometryReader { geometry in
                Color.clear
                    .preference(key: FramePreferenceKey.self, value: geometry.frame(in: .global))
            }
            .onPreferenceChange(FramePreferenceKey.self) { value in
                self.viewModel.currentFrame = value
            }
        }


}

struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

//struct ImageViewing_Previews: PreviewProvider {
//    
//    
//    static var previews: some View {
//        NavigationView {
//            let url = Bundle.main.url(forResource: "1", withExtension: "JPG")!
//            ImageViewing(currentScale: .constant(1.0), finalOffset: .constant(.zero), viewModel: .init(media: EncryptedMedia(source: url)!, fileAccess: DemoFileEnumerator()), externalGesture: DragGesture())
//                .frame(maxWidth: .infinity, maxHeight: .infinity)
//        }
//    }
//}
