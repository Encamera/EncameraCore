//
//  TaskProgressRow.swift
//  Encamera
//
//  Created by Alexander Freas on 24.07.25.
//



import SwiftUI
import EncameraCore
import Combine
import Photos

struct TaskProgressRow: View {
    let task: ImportTask
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    @State private var showDeleteConfirmation = false
    @State private var showPhotoAccessAlert = false
    @State private var isDeletingPhotos = false
    
    var body: some View {
        HStack(spacing: 12) {
            // State indicator
            stateIcon
            
            // Progress info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(task.progress.currentFileIndex + 1) of \(task.progress.totalFiles) files")
                        .fontType(.pt12, weight: .medium)
                        .foregroundColor(.foregroundPrimary)
                    
                    Spacer()
                    
                    Text("\(Int(task.progress.overallProgress * 100))%")
                        .fontType(.pt12, weight: .medium)
                        .foregroundColor(.actionYellowGreen
)
                }

                ProgressView(value: task.progress.overallProgress, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: progressColor))
                    .frame(height: 3)
                
                if let fileName = task.progress.currentFileName {
                    Text("Processing: \(fileName)")
                        .fontType(.pt10)
                        .foregroundColor(.actionYellowGreen
)
                        .lineLimit(1)
                }
                
                // Show delete from photos button if we have asset identifiers
                if !task.assetIdentifiers.isEmpty && (task.state == .completed || task.state == .paused) {
                    Button(action: {
                        showDeleteConfirmation = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 10))
                            Text("Delete from Photos")
                                .fontType(.pt10, weight: .medium)
                        }
                        .foregroundColor(.red)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                    }
                    .disabled(isDeletingPhotos)
                }
            }
            
            // Control buttons
            HStack(spacing: 8) {
                switch task.state {
                case .running:
                    Button(action: {
                        importManager.pauseImport(taskId: task.id)
                    }) {
                        Image(systemName: "pause.circle.fill")
                            .foregroundColor(.actionYellowGreen)
                            .font(.system(size: 18))
                    }
                    
                case .paused:
                    Button(action: {
                        Task {
                            try? await importManager.resumeImport(taskId: task.id)
                        }
                    }) {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.actionYellowGreen)
                            .font(.system(size: 18))
                    }
                    
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.actionYellowGreen)
                        .font(.system(size: 18))
                    
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 18))
                    
                default:
                    EmptyView()
                }
                
                Button(action: {
                    importManager.cancelImport(taskId: task.id)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.actionYellowGreen)
                        .font(.system(size: 16))
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.inputFieldBackgroundColor)
        .cornerRadius(8)
        .alert("Delete from Photo Library?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task {
                    await checkPermissionsAndDelete()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete \(task.assetIdentifiers.count) photo(s) from your Photo Library that were imported into Encamera.")
        }
        .alert("Photo Library Access Required", isPresented: $showPhotoAccessAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please grant full access to your photo library in Settings to delete imported photos.")
        }
    }
    
    private func checkPermissionsAndDelete() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized:
            // Full access - can delete
            await deletePhotosFromLibrary()
        case .limited:
            // Limited access - can't delete
            await MainActor.run {
                showPhotoAccessAlert = true
            }
        case .notDetermined:
            // Request permission
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if newStatus == .authorized {
                await deletePhotosFromLibrary()
            } else {
                await MainActor.run {
                    showPhotoAccessAlert = true
                }
            }
        case .denied, .restricted:
            // No access
            await MainActor.run {
                showPhotoAccessAlert = true
            }
        @unknown default:
            break
        }
    }
    
    private func deletePhotosFromLibrary() async {
        await MainActor.run {
            isDeletingPhotos = true
        }
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: task.assetIdentifiers, options: nil)
        
        if assets.count > 0 {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets)
                }
                debugPrint("Successfully deleted \(assets.count) photos from Photo Library")
                
                // Track the deletion
                EventTracking.trackMediaDeleted(count: assets.count)
                
                // Remove the task after successful deletion
                await MainActor.run {
                    importManager.cancelImport(taskId: task.id)
                }
            } catch {
                debugPrint("Failed to delete photos: \(error)")
            }
        } else {
            debugPrint("No assets found to delete")
        }
        
        await MainActor.run {
            isDeletingPhotos = false
        }
    }
    
    private var stateIcon: some View {
        Group {
            switch task.state {
            case .running:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .actionYellowGreen))
                    .scaleEffect(0.8)
            case .paused:
                Image(systemName: "pause.circle")
                    .foregroundColor(.orange)
                    .font(.system(size: 20))
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 20))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 20))
            case .cancelled:
                Image(systemName: "xmark.circle")
                    .foregroundColor(.actionYellowGreen
)
                    .font(.system(size: 20))
            case .idle:
                Image(systemName: "clock")
                    .foregroundColor(.actionYellowGreen
)
                    .font(.system(size: 20))
            }
        }
        .frame(width: 24, height: 24)
    }
    
    private var progressColor: Color {
        switch task.state {
        case .running:
            return .actionYellowGreen
        case .paused:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        default:
            return .actionYellowGreen

        }
    }
}