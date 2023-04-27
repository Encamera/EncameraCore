//
//  GalleryView.swift
//  Encamera
//
//  Created by Alexander Freas on 25.11.21.
//

import SwiftUI
import Combine
import EncameraCore

@MainActor
class GalleryGridViewModel: ObservableObject {
    
    var privateKey: PrivateKey
    var purchasedPermissions: PurchasedPermissionManaging
    @MainActor
    @Published var media: [EncryptedMedia] = []
    @Published var showingCarousel = false
    @Published var downloadPendingMediaCount: Int = 0
    @Published var downloadInProgress = false
    @Published var blurImages = false
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
         blurImages: Bool = false,
         showingCarousel: Bool = false,
         downloadPendingMediaCount: Int = 0,
         carouselTarget: EncryptedMedia? = nil,
         fileAccess: FileAccess = DiskFileAccess(),
         purchasedPermissions: PurchasedPermissionManaging = AppPurchasedPermissionUtils()
    ) {
        self.blurImages = blurImages
        self.privateKey = privateKey
        self.showingCarousel = showingCarousel
        self.downloadPendingMediaCount = downloadPendingMediaCount
        self.carouselTarget = carouselTarget
        self.fileAccess = fileAccess
        self.purchasedPermissions = purchasedPermissions
    }
    
    func startiCloudDownload() {
        let directory = storageSetting.storageModelFor(keyName: privateKey.name)
        if let iCloudStorageDirectory = directory as? iCloudStorageModel {
            iCloudStorageDirectory.triggerDownloadOfAllFilesFromiCloud()
        } else {
            return
        }
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
        downloadPendingMediaCount = media.filter({$0.needsDownload == true}).count
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
    
    func blurItemAt(index: Int) -> Bool {
        return purchasedPermissions.isAllowedAccess(feature: .accessPhoto(count: Double(index))) == false
    }
    
}

private enum Constants {
    static let hideButtonWidth = 100.0
    static let numberOfImagesWide = 3.0
    static let blurRadius = AppConstants.blockingBlurRadius
    static let buttonPadding = 7.0
    static let buttonCornerRadius = 10.0
}

struct GalleryGridView<Content: View>: View {
    
    @StateObject var viewModel: GalleryGridViewModel
    var content: Content
    
    init(viewModel: GalleryGridViewModel, @ViewBuilder content: () -> Content = { EmptyView() }) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.content = content()
    }
    
    
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let side = frame.width / Constants.numberOfImagesWide
            let gridItems = [
                GridItem(.fixed(side), spacing: 1),
                GridItem(.fixed(side), spacing: 1),
                GridItem(.fixed(side), spacing: 1)
            ]
            ZStack {
                ScrollView {
                    content
                    HStack {
                        Group {
                            if viewModel.blurImages {
                                Toggle(L10n.hide, isOn: $viewModel.blurImages)
                                    .frame(width: Constants.hideButtonWidth)
                                    .fontType(.small)
                                Spacer()
                            } else {
                                Text(L10n.imageS(viewModel.media.count))
                                    .fontType(.small)
                            }
                        }.onTapGesture {
                            viewModel.blurImages.toggle()
                        }
                        if viewModel.downloadPendingMediaCount > 0 {
                            downloadFromiCloudButton
                        }
                        Spacer()
                        Button {
                            LocalDeeplinkingUtils.openKeyContentsInFiles(keyName: viewModel.privateKey.name)
                        } label: {
                            Image(systemName: "folder")
                                .foregroundColor(.foregroundPrimary)
                        }
                    }
                    .padding()
                    
                    LazyVGrid(columns: gridItems, spacing: 1) {
                        ForEach(Array(viewModel.media.enumerated()), id: \.element) { index, mediaItem in
                            AsyncEncryptedImage(viewModel: .init(targetMedia: mediaItem, loader: viewModel.fileAccess), placeholder: ProgressView())
                                .onTapGesture {
                                    viewModel.carouselTarget = mediaItem
                                }
                                .blur(radius: viewModel.blurItemAt(index: index) ? Constants.blurRadius : 0.0)
                        }
                    }
                    .blur(radius: viewModel.blurImages ? Constants.buttonCornerRadius : 0.0)
                    .animation(.easeIn, value: viewModel.blurImages)
                }
                
                
                NavigationLink(isActive: $viewModel.showingCarousel) {
                    if let carouselTarget = viewModel.carouselTarget, viewModel.showingCarousel == true {
                        
                        GalleryHorizontalScrollView(
                            viewModel: .init(
                                media: viewModel.media,
                                selectedMedia: carouselTarget,
                                fileAccess: viewModel.fileAccess,
                                purchasedPermissions: viewModel.purchasedPermissions
                            ))
                    }
                } label: {
                    EmptyView()
                }
                
            }
            .task {
                await viewModel.enumerateMedia()
            }
            .onAppear {
                AskForReviewUtil.askForReviewIfNeeded()
            }
            .screenBlocked()
            .background(Color.background)
            .navigationBarTitle(viewModel.privateKey.name, displayMode: .large)
            
        }
        .onAppear {
            Task {
                await viewModel.enumerateMedia()
            }
        }
    }
    
    
    var downloadFromiCloudButton: some View {
        Button {
            viewModel.startiCloudDownload()
        } label: {
            
            HStack {
                if viewModel.downloadInProgress {
                    ProgressView()
                        .tint(Color.foregroundPrimary)
                    Spacer()
                        .frame(width: 5)
                } else {
                    Text("\(viewModel.downloadPendingMediaCount)")
                        .fontType(.small)
                }
                Image(systemName: "icloud.and.arrow.down")
            }
        }
        .padding(Constants.buttonPadding)
            .background(Color.foregroundSecondary)
            .cornerRadius(Constants.buttonCornerRadius)

    }
}

struct GalleryView_Previews: PreviewProvider {
    
    static var previews: some View {
        NavigationView {
            GalleryGridView(viewModel: GalleryGridViewModel(
                
                privateKey: DemoPrivateKey.dummyKey(),
                blurImages: true,
                downloadPendingMediaCount: 20,
                
                fileAccess: DemoFileEnumerator()
            ))
        }
    }
}
