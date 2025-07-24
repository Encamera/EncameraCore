//
//  TaskDetailCard.swift
//  Encamera
//
//  Created by Alexander Freas on 24.07.25.
//



import SwiftUI
import EncameraCore
import Combine
import Photos

struct TaskDetailCard: View {
    let task: ImportTask
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    @State private var showDeleteConfirmation = false
    @State private var showPhotoAccessAlert = false
    @State private var isDeletingPhotos = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task ID: \(String(task.id.prefix(8)))")
                        .fontType(.pt14, weight: .semibold)
                        .foregroundColor(.foregroundPrimary)
                    
                    Text("Created: \(task.createdAt, formatter: dateFormatter)")
                        .fontType(.pt12)
                        .foregroundColor(.actionYellowGreen)
                }
                
                Spacer()
                
                Text(stateText)
                    .fontType(.pt12, weight: .medium)
                    .foregroundColor(stateColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(stateColor.opacity(0.1))
                    .cornerRadius(4)
            }
            
            // Progress details
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Progress:")
                        .fontType(.pt12, weight: .medium)
                    Spacer()
                    Text("\(task.progress.currentFileIndex + 1) / \(task.progress.totalFiles) files")
                        .fontType(.pt12)
                        .foregroundColor(.actionYellowGreen
)
                }
                
                ProgressView(value: task.progress.overallProgress, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .actionYellowGreen))
                
                if let fileName = task.progress.currentFileName {
                    Text("Current: \(fileName)")
                        .fontType(.pt10)
                        .foregroundColor(.actionYellowGreen
)
                }
                
                if let eta = task.progress.estimatedTimeRemaining {
                    Text("Estimated time remaining: \(timeFormatter.string(from: eta) ?? "Unknown")")
                        .fontType(.pt10)
                        .foregroundColor(.actionYellowGreen
)
                }
            }
            
            // Action buttons
            HStack(spacing: 0.0) {
                switch task.state {
                case .running:
                    Button("Pause") {
                        importManager.pauseImport(taskId: task.id)
                    }
                    .primaryButton()
                    
                case .paused:
                    Button("Resume") {
                        Task {
                            try? await importManager.resumeImport(taskId: task.id)
                        }
                    }
                    .primaryButton()
                    
                case .completed:
                    Button("Delete Media From Camera Roll") {
                        showDeleteConfirmation = true
                    }
                    .primaryButton()
                    .disabled(isDeletingPhotos)
                    
                default:
                    EmptyView()
                }
                
                // Show cancel button for non-completed tasks
                if task.state != .completed {
                    Button("Cancel") {
                        importManager.cancelImport(taskId: task.id)
                    }
                    .primaryButton()
                }
                
                Spacer()
            }
        }
        .padding()
        .background(Color.inputFieldBackgroundColor)
        .cornerRadius(12)
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
    
    private var stateText: String {
        switch task.state {
        case .idle: return "Waiting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }
    
    private var stateColor: Color {
        switch task.state {
        case .idle: return .actionYellowGreen

        case .running: return .actionYellowGreen
        case .paused: return .orange
        case .completed: return .green
        case .cancelled: return .actionYellowGreen

        case .failed: return .red
        }
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }
    
    private var timeFormatter: DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }
} 
