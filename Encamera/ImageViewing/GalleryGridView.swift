//
//  GalleryView.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI
import Combine


@MainActor
class GalleryGridViewModel: ObservableObject {
    
    var privateKey: PrivateKey
    @Published var media: [EncryptedMedia] = []
    @Published var showingCarousel = false
    @Published var downloadPendingMediaCount: Int = 0
    @Published var downloadInProgress = false
    @Published var carouselTarget: EncryptedMedia? {
        didSet {
            if carouselTarget == nil {
                showingCarousel = false
            } else {
                showingCarousel = true
            }
        }
    }
    private var cancellables = Set<AnyCancellable>()
    var fileAccess: FileAccess = DiskFileAccess()
    var storageSetting = DataStorageUserDefaultsSetting()
    
    init(privateKey: PrivateKey,
         showingCarousel: Bool = false,
         downloadPendingMediaCount: Int = 0,
         carouselTarget: EncryptedMedia? = nil,
         fileAccess: FileAccess = DiskFileAccess()
    ) {
        self.privateKey = privateKey
        self.showingCarousel = showingCarousel
        self.downloadPendingMediaCount = downloadPendingMediaCount
        self.carouselTarget = carouselTarget
        self.fileAccess = fileAccess
    }
    
    func startiCloudDownload() {
        let directory = storageSetting.storageModelFor(keyName: privateKey.name)
        directory?.triggerDownload()
        downloadInProgress = true
        Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .receive(on: DispatchQueue.main)
            .sink { out in
                Task {
                    await self.enumerateMedia()
                }
            }
            .store(in: &cancellables)
    }
    
    func enumerateiCloudUndownloaded() {
        let directory = storageSetting.storageModelFor(keyName: privateKey.name)
        downloadPendingMediaCount = directory?.enumeratorForStorageDirectory(fileExtensionFilter: ["icloud"]).count ?? 0
        if downloadPendingMediaCount == 0 {
            downloadInProgress = false
            cancellables.forEach({$0.cancel()})
        }
    }
    
    func enumerateMedia() async {
        await fileAccess.configure(with: privateKey, storageSettingsManager: storageSetting)
        let enumerated: [EncryptedMedia] = await fileAccess.enumerateMedia()
        media = enumerated
        enumerateiCloudUndownloaded()
    }
}

struct GalleryGridView<Content: View>: View {
    
    @StateObject var viewModel: GalleryGridViewModel
    var content: Content
    
    init(viewModel: GalleryGridViewModel, content: () -> Content = { EmptyView() }) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.content = content()
    }
    
    var body: some View {
        let gridItems = [
            GridItem(.adaptive(minimum: 100), spacing: 1)
        ]
        ZStack {
            ScrollView {
                content
                HStack {
                    Text("\(viewModel.media.count) image\(viewModel.media.count == 1 ? "" : "s")")
                        .foregroundColor(.white)
                    if viewModel.downloadPendingMediaCount > 0 {
                        Button {
                            viewModel.startiCloudDownload()
                        } label: {
                            
                            HStack {
                                if viewModel.downloadInProgress {
                                    ProgressView()
                                        .tint(Color.white)
                                    Spacer()
                                        .frame(width: 5)
                                } else {
                                    Text("\(viewModel.downloadPendingMediaCount)")
                                }
                                Image(systemName: "icloud.and.arrow.down")
                            }
                            
                            
                        }.foregroundColor(.white)
                            .padding(5)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }

                    Spacer()
                    
                    Button {
                        LocalDeeplinkingUtils.openKeyContentsInFiles(keyName: viewModel.privateKey.name)
                    } label: {
                        Image(systemName: "folder")
                    }
                    

                }.padding()
                LazyVGrid(columns: gridItems, spacing: 1) {
                    ForEach(viewModel.media, id: \.gridID) { mediaItem in
                        
                        GalleryItem(fileAccess: viewModel.fileAccess, media: mediaItem)
                            .onTapGesture {
                                viewModel.carouselTarget = mediaItem
                            }
                    }
                }
            }
            
            
            NavigationLink(isActive: $viewModel.showingCarousel) {
                if let carouselTarget = viewModel.carouselTarget, viewModel.showingCarousel == true {
                    
                    GalleryHorizontalScrollView(
                        viewModel: .init(media: viewModel.media, selectedMedia: carouselTarget, fileAccess: viewModel.fileAccess))
                }
            } label: {
                EmptyView()
            }
            
        }
        .task {
            await viewModel.enumerateMedia()
        }
        .background(Color.black)
        .screenBlocked()
        .navigationBarTitle(viewModel.privateKey.name, displayMode: .large)
        
    }
}

struct GalleryView_Previews: PreviewProvider {
    
    static var previews: some View {
        NavigationView {
            GalleryGridView(viewModel: GalleryGridViewModel(
                privateKey: DemoPrivateKey.dummyKey(),
                downloadPendingMediaCount: 20,
                fileAccess: DemoFileEnumerator()
            ))
        }
    }
}
