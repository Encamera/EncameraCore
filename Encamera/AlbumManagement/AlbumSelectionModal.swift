//
//  AlbumSelectionModal.swift
//  Encamera
//
//  Created by AI Assistant
//

import SwiftUI
import EncameraCore

struct AlbumSelectionModal: View {
    
    let context: AlbumSelectionContext
    @State private var selectedAlbum: Album?
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack {
                Spacer()
                ZStack(alignment: .bottom) {
                    ZStack(alignment: .init(horizontal: .trailing, vertical: .top)) {
                        
                        VStack(alignment: .center, spacing: 25) {
                            
                            Image(systemName: "folder")
                                .resizable()
                                .frame(width: 60, height: 60)
                                .foregroundColor(.white)
                            
                            Text("Move to Album")
                                .fontType(.pt24, weight: .bold)
                            
                            Text("Select an album to move \(context.selectedMedia.count) items to")
                                .lineLimit(2, reservesSpace: true)
                                .fontType(.pt16)
                                .multilineTextAlignment(.center)
                            
                            ScrollView {
                                VStack(spacing: 12) {
                                    ForEach(context.availableAlbums, id: \.id) { album in
                                        AlbumSelectionRow(
                                            album: album,
                                            isSelected: selectedAlbum?.id == album.id,
                                            onTap: {
                                                selectedAlbum = album
                                            }
                                        )
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            .frame(maxHeight: 300)
                            
                            HStack(spacing: 16) {
                                Button("Cancel") {
                                    context.onDismiss()
                                }
                                .secondaryButton()
                                
                                Button("Move") {
                                    guard let selectedAlbum = selectedAlbum else { return }
                                    context.onAlbumSelected(selectedAlbum)
                                }
                                .disabled(selectedAlbum == nil)
                                .primaryButton(enabled: selectedAlbum != nil)
                            }
                        }
                        .padding(.init(top: 40, leading: 16, bottom: 40, trailing: 16))
                        .background(Color.modalBackgroundColor)
                        .cornerRadius(AppConstants.defaultCornerRadius)
                        
                        DismissButton(action: context.onDismiss)
                            .padding()
                    }
                    .frame(maxHeight: 600)
                }
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .background(.ultraThinMaterial)
        .gradientBackground()
    }
}

struct AlbumSelectionRow: View {
    let album: Album
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.name)
                        .fontType(.pt16, weight: .medium)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                    
                    Text("\(album.storageOption.rawValue.capitalized) Storage")
                        .fontType(.pt12)
                        .foregroundColor(.white)
                        .opacity(0.7)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.activeKey)
                        .font(.title2)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.white)
                        .opacity(0.3)
                        .font(.title2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                    .stroke(isSelected ? Color.activeKey : Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    let dummyKey = DemoPrivateKey.dummyKey()
    let sampleAlbums = [
        Album(name: "Personal Photos", storageOption: .local, creationDate: Date(), key: dummyKey),
        Album(name: "Work Documents", storageOption: .icloud, creationDate: Date(), key: dummyKey),
        Album(name: "Family Memories", storageOption: .local, creationDate: Date(), key: dummyKey)
    ]
    
    let context = AlbumSelectionContext(
        sourceView: "Preview",
        availableAlbums: sampleAlbums,
        currentAlbum: Album(name: "Current Album", storageOption: .local, creationDate: Date(), key: dummyKey),
        selectedMedia: Set([]),
        onAlbumSelected: { _ in },
        onDismiss: { }
    )
    
    AlbumSelectionModal(context: context)
}