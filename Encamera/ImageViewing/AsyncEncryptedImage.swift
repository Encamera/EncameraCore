//
//  AsyncImage.swift
//  Encamera
//
//  Created by Alexander Freas on 17.06.22.
//

import Combine
import SwiftUI
import EncameraCore

struct AsyncEncryptedImage<Placeholder: View>: View, Identifiable  {

    @MainActor
    class ViewModel: ObservableObject {
        private var loader: FileReader
        private var targetMedia: InteractableMedia<EncryptedMedia>
        @Published var cleartextMedia: PreviewModel?
        @Published var error: Error?

        var needsDownload: Bool {
            targetMedia.needsDownload
        }

        init(targetMedia: InteractableMedia<EncryptedMedia>, loader: FileReader, isInSelectionMode: Bool = false, isSelected: Bool = false) {
            self.targetMedia = targetMedia
            self.loader = loader
        }

        func loadPreview() async {
            do {
                let preview = try await loader.loadMediaPreview(for: targetMedia)
                await MainActor.run {
                    cleartextMedia = preview
                }
            } catch let err as SecretFilesError {
                debugPrint("Error loading preview: \(err)")
                self.error = err
            } catch {
                debugPrint("Error loading preview: \(error)")
                self.error = SecretFilesError.sourceFileAccessError("generic error")
            }
        }
    }
    var id: String = NSUUID().uuidString

    @StateObject var viewModel: ViewModel
    var placeholder: Placeholder
    @Binding var isInSelectionMode: Bool
    @Binding var isSelected: Bool
    @Binding var isBlurred: Bool

    var body: some View {
        ZStack {

            if let decrypted = viewModel.cleartextMedia?.thumbnailMedia.data,
               let image = UIImage(data: decrypted) {
                bodyContainer {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .blur(radius: isBlurred ? AppConstants.blockingBlurRadius : 0.0)
                if viewModel.needsDownload {
                    ZStack(alignment: .topTrailing) {
                        Rectangle().foregroundColor(.clear)
                        Image(systemName: "icloud")
                            .foregroundColor(.white)
                    }
                    .padding(3)

                }

                if !isSelected && (viewModel.cleartextMedia?.videoDuration != nil || viewModel.cleartextMedia?.isLivePhoto == true) {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            if viewModel.cleartextMedia?.isLivePhoto == true {
                                Image(systemName: "livephoto")
                                    .padding(2.0)
                            } else if let duration = viewModel.cleartextMedia?.videoDuration  {
                                Text(duration)
                                    .font(.system(size: 12, weight: .bold))
                                    .padding(2.0)

                            }
                        }

                    }
                }


            } else if let error = viewModel.error {

                bodyContainer {
                    switch error {
                    case SecretFilesError.createVideoThumbnailError:
                        Image(systemName: "play.rectangle.fill")
                    default:
                        Image(systemName: "x.square")
                    }

                }.task {
                    await viewModel.loadPreview()
                }


            } else {
                bodyContainer {
                    placeholder.task {
                        await viewModel.loadPreview()
                    }
                }
            }
            if isInSelectionMode && isSelected {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                            .background(Circle().foregroundColor(.white))
                            .padding(5.0)
                    }
                }
            }
        }

    }

    @ViewBuilder func bodyContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .background {
                ZStack {
                    Color.disabledButtonBackgroundColor
                    content()

                }
            }
            .aspectRatio(contentMode:.fill)
            .clipped()
            .contentShape(Rectangle())
            .if(isInSelectionMode) { view in
                view.onTapGesture {
                    isSelected.toggle()
                }
            }
        
    }
}
//
struct AsyncImage_Previews: PreviewProvider {

    static var previews: some View {
        NavigationView {

            GalleryGridView(viewModel: GalleryGridViewModel(
                album: DemoAlbumManager().currentAlbum,
                albumManager: DemoAlbumManager(),
                blurImages: false,
                downloadPendingMediaCount: 22,
                fileAccess: DemoFileEnumerator()
            ))
        }
    }
}
