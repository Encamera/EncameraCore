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
    
    func decryptAndSet() {
        Task {
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
    }
    
}

struct ImageViewing<M: MediaDescribing>: View {
    
    @Binding var currentScale: CGFloat
    @Binding var finalOffset: CGSize
    @State var currentOffset: CGSize = .zero
    @State var showBottomActions = false
    var isActive: Binding<Bool>
    @StateObject var viewModel: ImageViewingViewModel<M>
    var externalGesture: DragGesture
    var cancellables = Set<AnyCancellable>()
    
    
    var body: some View {
//        GeometryReader { geo in
//            let frame = geo.frame(in: .local)
        ZStack {
            if let imageData = viewModel.decryptedFileRef?.source,
               let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                
//                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(currentScale)
                    .offset(
                        x: finalOffset.width + currentOffset.width,
                        y: finalOffset.height + currentOffset.height
                    )
                    .animation(.easeInOut, value: currentScale)
                    .animation(.easeInOut, value: finalOffset)
                    .zIndex(1)
                
            } else if let error = viewModel.error {
                Text("Could not decrypt image: \(error.localizedDescription)")
                    .foregroundColor(.red)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            viewModel.decryptAndSet()
        }
        .navigationTitle("\(viewModel.decryptedFileRef?.id ?? "None")")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black)
    }
}

struct ImageViewing_Previews: PreviewProvider {
    
    
    static var previews: some View {
        NavigationView {
            let url = Bundle.main.url(forResource: "image", withExtension: "jpg")!
            ImageViewing(currentScale: .constant(1.0), finalOffset: .constant(.zero), isActive: .constant(false), viewModel: .init(media: EncryptedMedia(source: url)!, fileAccess: DemoFileEnumerator()), externalGesture: DragGesture())
        }
    }
}
