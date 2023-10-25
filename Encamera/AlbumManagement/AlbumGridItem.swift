//
//  AlbumGridItem.swift
//  Encamera
//
//  Created by Alexander Freas on 28.11.22.
//

import SwiftUI
import Combine
import EncameraCore

actor KeyInfoFetcher {
    
}
class AlbumGridItemModel: ObservableObject {
    
    var fileReader: FileReader = DiskFileAccess()
    var storageModel: DataStorageModel?
    var storageType: StorageType? {
        storageModel?.storageType
    }
    
    @Published var countOfMedia: Int = 0

    init(key: PrivateKey) {
        Task {
            await fileReader.configure(
                with: key,
                storageSettingsManager: DataStorageUserDefaultsSetting()
            )
            
        }
        storageModel = DataStorageUserDefaultsSetting().storageModelFor(keyName: key.name)
        self.countOfMedia = storageModel?.countOfFiles(matchingFileExtension: [MediaType.photo.fileExtension, MediaType.video.fileExtension]) ?? 0

    }
}
struct GeneralPurposeView: View {

    @State var image: Image?
    var title: String
    var subheading: String?
    var width: CGFloat
    var strokeStyle: StrokeStyle? = nil
    var shouldResizeImage: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .stroke(style: strokeStyle ?? StrokeStyle(lineWidth: 0))
                .background {
                if let image = image {
                    if shouldResizeImage {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        image
                    }

                } else {
                    Color.inputFieldBackgroundColor // replace with an actual color or view
                }
            }
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .circular))
            .padding(.bottom, 12)


            Text(title)
                .fontType(.pt14, weight: .bold) // replace with actual font

//            if let subheading = subheading {
                Text(subheading ?? "")
                .lineLimit(1, reservesSpace: true)
                    .fontType(.pt14) // replace with actual font
//            }
        }
    }
}
struct AlbumGridItem: View {

    @ObservedObject var viewModel: AlbumGridItemModel
    @State var imageCount: Int?
    @State var leadingImage: UIImage?
    var keyName: String
    var width: CGFloat

    init(key: PrivateKey, width: CGFloat) {
        keyName = key.name
        self.viewModel = AlbumGridItemModel(key: key)
        self.width = width
    }

    func load() {
        Task {
            let thumb = try await viewModel.fileReader.loadLeadingThumbnail()
            await MainActor.run {
                self.imageCount = viewModel.countOfMedia
                self.leadingImage = thumb
            }
        }
    }

    var body: some View {
        
        GeneralPurposeView(image: leadingImage != nil ? Image(uiImage: leadingImage!) : nil,
                           title: keyName,
                           subheading: imageCount != nil ? "\(imageCount!) items" : nil,
                           width: width)
            .task {
                load()
            }
    }
}




struct AlbumGridItem_Previews: PreviewProvider {
    static var previews: some View {
        
        AlbumGrid(viewModel: .init(keyManager: DemoKeyManager(keys: [            DemoPrivateKey.dummyKey(name: "cats and their people"),
                                                         DemoPrivateKey.dummyKey(name: "dogs"),
                                                         DemoPrivateKey.dummyKey(name: "rats"),
                                                         DemoPrivateKey.dummyKey(name: "mice"),
                                                         DemoPrivateKey.dummyKey(name: "cows"),
                                                         DemoPrivateKey.dummyKey(name: "very very very very very very long name that could overflow"),
                                                                           ]), purchaseManager: AppPurchasedPermissionUtils(), fileManager: DemoFileEnumerator()))
        .preferredColorScheme(.dark)
    }
        
}
