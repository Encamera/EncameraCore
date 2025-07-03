import SwiftUI
import PhotosUI

// iOS 17+ Embedded Photo Picker with Continuous Selection
// This provides a more integrated experience than the modal picker
struct EmbeddedPhotoPicker: View {
    @Binding var selectedItems: [PhotosPickerItem]
    var filter: PHPickerFilter = .images
    
    // For handling PHPickerResult if needed for compatibility
    var onSelectionComplete: (([PHPickerResult]) -> Void)?
    
    @State private var selectedPhotos: [UIImage] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Selected photos preview
            if !selectedPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(selectedPhotos.enumerated()), id: \.offset) { index, photo in
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    // Selection order number
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundColor(.white)
                                        .padding(4)
                                        .background(Color.blue)
                                        .clipShape(Circle())
                                        .padding(4),
                                    alignment: .topTrailing
                                )
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 80)
                .background(Color(UIColor.systemGray6))
            }
            
            // Embedded picker
            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: nil, // nil for unlimited
                selectionBehavior: .continuous, // iOS 17+ - provides live updates
                matching: filter,
                preferredItemEncoding: .current,
                photoLibrary: .shared()
            ) {
                // Empty label - the picker will be embedded
                EmptyView()
            }
            .photosPickerStyle(.inline) // iOS 17+ - embeds the picker
            .photosPickerDisabledCapabilities([]) // Keep all capabilities
            .photosPickerAccessoryVisibility(.visible) // Show all accessories
            .ignoresSafeArea(edges: .bottom)
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    await loadPhotos(from: newItems)
                }
            }
        }
    }
    
    private func loadPhotos(from items: [PhotosPickerItem]) async {
        var photos: [UIImage] = []
        
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                photos.append(image)
            }
        }
        
        await MainActor.run {
            self.selectedPhotos = photos
        }
    }
}

// MARK: - Usage Example
struct EmbeddedPickerExample: View {
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var showEmbeddedPicker = false
    
    var body: some View {
        NavigationStack {
            VStack {
                if showEmbeddedPicker {
                    EmbeddedPhotoPicker(selectedItems: $selectedItems)
                        .transition(.move(edge: .bottom))
                } else {
                    Button("Show Embedded Picker") {
                        withAnimation {
                            showEmbeddedPicker = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Photos")
            .toolbar {
                if showEmbeddedPicker {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            withAnimation {
                                showEmbeddedPicker = false
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Compact Style Picker (iOS 17+)
// Single row horizontal picker
struct CompactPhotoPicker: View {
    @Binding var selectedItems: [PhotosPickerItem]
    var filter: PHPickerFilter = .images
    
    var body: some View {
        PhotosPicker(
            selection: $selectedItems,
            selectionBehavior: .continuous,
            matching: filter,
            photoLibrary: .shared()
        ) {
            Label("Add Photos", systemImage: "photo.on.rectangle.angled")
        }
        .photosPickerStyle(.compact) // iOS 17+ - single row style
    }
} 