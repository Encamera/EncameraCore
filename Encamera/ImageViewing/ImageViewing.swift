//
//  ImageViewing.swift
//  encamera
//
//  Created by Alexander Freas on 12.11.21.
//

import SwiftUI
import Combine
import PDFKit

struct PhotoDetailView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument()
        guard let page = PDFPage(image: image) else { return view }
        view.document?.insert(page, at: 0)
        view.autoScales = true
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // empty
    }
}

enum MediaViewingError: Error {
    case noKeyAvailable
    case fileAccessNotAvailable
    case decryptError(wrapped: Error)
}

protocol MediaViewingViewModel: AnyObject {
    
    associatedtype SourceType = MediaDescribing
    associatedtype TargetT: MediaSourcing
    
    var sourceMedia: SourceType { get set }
    var fileAccess: FileAccess? { get set }
    var error: MediaViewingError? { get set }

    var decryptedFileRef: CleartextMedia<TargetT>? { get set }
    init(media: SourceType, fileAccess: FileAccess)
    
    func decrypt() async throws -> CleartextMedia<TargetT>
}

extension MediaViewingViewModel {
    @MainActor
    func decryptAndSet() async {
        do {
            let result = try await decrypt()
            print("result", result, print(Unmanaged.passUnretained(self).toOpaque())
)
            self.decryptedFileRef = result
        } catch {
            self.error = .decryptError(wrapped: error)
        }
    }
    
    func cleanup() {
        do {
            try decryptedFileRef?.delete()
        } catch {
            debugPrint("Could not delete file ref \(error)")
        }
    }
}

class ImageViewingViewModel<SourceType: MediaDescribing>: ObservableObject {
    @Published var decryptedFileRef: CleartextMedia<Data>?
    var sourceMedia: SourceType
    var fileAccess: FileAccess?
    var error: MediaViewingError?

    required init(media: SourceType, fileAccess: FileAccess) {
        self.sourceMedia = media
        self.fileAccess = fileAccess
    }
    
    func decryptAndSet() async {
        do {
            let result = try await fileAccess!.loadMediaInMemory(media: sourceMedia) { progress in
                
            }
            await MainActor.run {
                self.decryptedFileRef = result
            }
            
        } catch {
            self.error = .decryptError(wrapped: error)
        }
    }
//    func decrypt() async throws -> CleartextMedia<Data> {
////        guard let fileAccess = fileAccess else {
////            throw MediaViewingError.fileAccessNotAvailable
////        }
////        return
//    }
}

struct ImageViewing<M: MediaDescribing>: View {
    
    @State var currentScale: CGFloat = 0.0
    @State var finalScale: CGFloat = 1.0
    @State var offset: CGPoint = .zero
    @ObservedObject var viewModel: ImageViewingViewModel<M>
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: ImageViewingViewModel<M>) {
        self.viewModel = viewModel
//        print("ImageViewingViewModel", self)
//        viewModel.$decryptedFileRef.sink { media in
//            print("media", media)
//        }.store(in: &cancellables)
        
        
    }
    
    
    
    var body: some View {
        VStack {
            
//            if let imageData = viewModel.decryptedFileRef?.source,
//               let image = UIImage(data: imageData) {
            if let imageData = try? Data(contentsOf: Bundle.main.url(forResource: "dog", withExtension: "jpg")!),
               let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(finalScale + currentScale)
                    .offset(x: offset.x, y: offset.y)
                
                    .gesture(
                        MagnificationGesture()
                            .onChanged({ value in
                                currentScale = value - 1
                            })
                            .onEnded({ amount in
                                finalScale += currentScale
                                currentScale = 0.0
                            })
                    )
                    .gesture(DragGesture().onChanged({ value in
                        self.offset = value.predictedEndLocation
                    }))
                    .gesture(TapGesture(count: 2).onEnded {
                        self.finalScale = 1.0
                    })
                    .animation(.easeInOut, value: currentScale)
            } else {
                Text("Could not decrypt image")
                    .foregroundColor(.red)
            }
        }.task {
            await viewModel.decryptAndSet()
        }
        
//        .onDisappear {
//            viewModel.cleanup()
//        }
        .navigationTitle("")
        .navigationBarHidden(true)
        .background(Color.black)
    }
}

struct ImageViewing_Previews: PreviewProvider {
    

    static var previews: some View {
        NavigationView {
            let url = Bundle.main.url(forResource: "image", withExtension: "jpg")!
        ImageViewing(viewModel: .init(media: EncryptedMedia(source: url)!, fileAccess: DemoFileEnumerator()))
        }
    }
}
