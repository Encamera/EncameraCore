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
    
    @State var currentScale: CGFloat = 0.0
    @State var finalScale: CGFloat = 1.0
    @State var finalOffset: CGSize = .zero
    @State var currentOffset: CGSize = .zero
    @State var showBottomActions = false
    var isActive: Binding<Bool>
    @StateObject var viewModel: ImageViewingViewModel<M>
    
    var cancellables = Set<AnyCancellable>()
    
//    init(viewModel: ImageViewingViewModel<M>, isActive: Binding<Bool>) {
//        self.viewModel = viewModel
//        self.isActive = isActive
//    }
    
    
    
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .local)
            
//            ScrollView {
                
                
                if let imageData = viewModel.decryptedFileRef?.source,
                   let image = UIImage(data: imageData) {
                    ////                if let imageData = try? Data(contentsOf: Bundle.main.url(forResource: "dog", withExtension: "jpg")!),
                    //                   let image = UIImage(data: imageData) {
                    
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(finalScale + currentScale)
                        .offset(
                            x: finalOffset.width + currentOffset.width,
                            y: finalOffset.height + currentOffset.height)
                    
//                        .gesture(DragGesture().onChanged({ value in
//                            if finalScale > 1.0 {
//                                var newOffset = value.translation
//                                if newOffset.height > frame.height * finalScale {
//                                    newOffset.height = frame.height * finalScale
//                                }
//
//                                currentOffset = newOffset
//                            }
//                        }).onEnded({ value in
//                            print("drag value", value.startLocation, value.location)
//
//                            if finalScale > 1.0 {
//
//
//                                let nextOffset: CGSize = .init(
//                                    width: finalOffset.width + currentOffset.width,
//                                    height: finalOffset.height + currentOffset.height)
//
//                                finalOffset = nextOffset
//                                currentOffset = .zero
//                            } else if  value.location.y - value.startLocation.y > 50 {
//                                isActive.wrappedValue = false
//                            }
//                        }))
//                        .gesture(
//                            MagnificationGesture()
//                                .onChanged({ value in
//                                    currentScale = value - 1
//                                    
//                                })
//                                .onEnded({ amount in
//                                    let final = finalScale + currentScale
//                                    finalScale = final < 1.0 ? 1.0 : final
//                                    currentScale = 0.0
//                                })
//                        )
//                    
//                        .gesture(TapGesture(count: 2).onEnded {
//                            finalScale = finalScale > 1.0 ? 1.0 : 3.0
//                            finalOffset = .zero
//                        })
                        .animation(.easeInOut, value: currentScale)
                        .animation(.easeInOut, value: finalOffset)
                        .zIndex(1)
                    
                } else {
                    Text("Could not decrypt image")
                        .foregroundColor(.red)
                }
                
//            }
        }.onAppear {
            viewModel.decryptAndSet()
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
//            ImageViewing(viewModel: .init(media: EncryptedMedia(source: url)!, fileAccess: DemoFileEnumerator()), simultaneousGesture: DragGesture())
        }
    }
}
