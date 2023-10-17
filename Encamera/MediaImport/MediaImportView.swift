//
//  MediaImportView.swift
//  Encamera
//
//  Created by Alexander Freas on 11.05.23.
//

import SwiftUI
import EncameraCore
import Combine

class MediaImportViewModel: ObservableObject {
    
    @Published var mediaToImport: [CleartextMedia<URL>] = []
    @Published var selectedMedia: Set<CleartextMedia<URL>> = Set()
    @Published var showDeleteAlert: Bool = false
    @Published var saveProgress: Double = 0.0
    var galleryViewModel: SelectableGalleryViewModel<CleartextMedia<URL>>
    var keyManager: KeyManager
    private var cancellables = Set<AnyCancellable>()
    private var fileAccess: FileAccess
    var appGroupFileAccess: FileAccess
    
    init(keyManager: KeyManager, fileAccess: FileAccess, appGroupFileAccess: FileAccess = AppGroupFileReader()) {
        self.appGroupFileAccess = appGroupFileAccess
        self.fileAccess = fileAccess
        self.keyManager = keyManager
        self.galleryViewModel = SelectableGalleryViewModel(media: [], fileAccess: appGroupFileAccess)
    }
    
    func loadMediaToImport() async {
        let media: [CleartextMedia<URL>] = await appGroupFileAccess.enumerateMedia()
        await MainActor.run {
            galleryViewModel.media = media
            galleryViewModel.$selectedMedia.sink(receiveValue: { selectedMedia in
                self.selectedMedia = selectedMedia
            }).store(in: &cancellables)
            mediaToImport = media
        }
    }
    
    func selectAllMedia() {
        let all = Set(mediaToImport)
        galleryViewModel.selectedMedia = all
        selectedMedia = all
    }
    
    func saveSelected() async {
        let mediaCount = Double(selectedMedia.count)
        var filesSaved = 0.0
        for media in selectedMedia {
            do {
                try await fileAccess.save(media: media) { fileProgress in
                    let currentFileProgress = fileProgress / mediaCount
                    let previousFilesProgress = filesSaved / mediaCount
                    let progress = previousFilesProgress + currentFileProgress
                    Task {
                        await MainActor.run {
                            self.saveProgress = progress
                        }
                    }
                    debugPrint("Finished saving \(Int(self.saveProgress * 100))%")
                }
            } catch {
                debugPrint("Could not save file:", error)
            }
            filesSaved += 1
        }
    }

    
    func deleteImages() {
        Task {
            do {
                try await appGroupFileAccess.deleteAllMedia()
            } catch {
                debugPrint("Could not delete all media: \(error)")
            }
        }
    }
}

struct MediaImportView: View {
    
    
    @StateObject var viewModel: MediaImportViewModel
    @Environment(\.dismiss) var dismiss

    init(viewModel: MediaImportViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    
    var body: some View {
            
            VStack {
                Group {
                    Text(L10n.importMedia)
                        .fontType(.medium)
                    Text("\(L10n.importSelectedImages) (\(viewModel.keyManager.currentKey?.name ?? ""))")
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                
                if viewModel.saveProgress == 0.0 {
                    HStack {
                        Spacer()
                        Button("Select All") {
                            viewModel.selectAllMedia()
                        }
                        .primaryButton()
                    }.padding()
                    SelectableGalleryView(viewModel: viewModel.galleryViewModel)
                        .task {
                            await viewModel.loadMediaToImport()
                        }
                    HStack {
                        Button(L10n.cancel) {
                            viewModel.showDeleteAlert = true
                        }
                        .primaryButton()
                        
                        Spacer()
                        Button("\(L10n.import) \(viewModel.selectedMedia.count)") {
                            Task {
                                await viewModel.saveSelected()
                                await MainActor.run {
                                    viewModel.showDeleteAlert = true
                                }
                                
                            }
                        }
                        .primaryButton(on: .elevated)
                    }.padding()
                } else {
                    
                    ProgressViewCircular(progress: Int(viewModel.saveProgress*100), total: 100)
                        .frame(width: 100, height: 100)
                    Text(L10n.encrypting)
                        .fontType(.pt24)
                    Spacer()
                }
                
            }
            .confirmationDialog(L10n.doYouWantToDeleteNotImported, isPresented: $viewModel.showDeleteAlert, titleVisibility: .visible, actions: {
                Button(L10n.notDoneYet) {
                    dismiss()
                }
                if viewModel.saveProgress != 1.0 {
                    Button(L10n.changeKeyAlbum) {
                        dismiss()
                    }
                }
                Button(L10n.iAmDone){
                    viewModel.deleteImages()
                    dismiss()
                }
            })
            .background(Color.background)
        
    }
}

struct MediaImportView_Previews: PreviewProvider {
    static var previews: some View {
        MediaImportView(viewModel: MediaImportViewModel(keyManager: DemoKeyManager(), fileAccess: DemoFileEnumerator(), appGroupFileAccess: DemoFileEnumerator()))
            .preferredColorScheme(.dark)
    }
}
