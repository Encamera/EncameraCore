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
    @StateObject private var deletionManager = PhotoDeletionManager()
    @State private var showDeleteConfirmation = false
    
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
            HStack(spacing: 10.0) {
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
                    Button("Delete From Camera Roll") {
                        showDeleteConfirmation = true
                    }
                    .primaryButton()
                    .disabled(deletionManager.isDeletingPhotos)
                    
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
            }
        }
        .padding()
        .background(Color.inputFieldBackgroundColor)
        .cornerRadius(12)
        .alert("Delete from Photo Library?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task {
                    await deletionManager.deletePhotos(assetIdentifiers: task.assetIdentifiers)
                    // Remove the task after successful deletion
                    importManager.cancelImport(taskId: task.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete \(task.assetIdentifiers.count) photo(s) from your Photo Library that were imported into Encamera.")
        }
        .alert("Photo Library Access Required", isPresented: $deletionManager.showPhotoAccessAlert) {
            Button("Open Settings") {
                deletionManager.openSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please grant full access to your photo library in Settings to delete imported photos.")
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

#Preview("Multiple States") {
    ScrollView {
        VStack(spacing: 16) {
            // Running state
            TaskDetailCard(task: MockImportTask.running)
            
            // Paused state
            TaskDetailCard(task: MockImportTask.paused)
            
            // Completed state
            TaskDetailCard(task: MockImportTask.completed)
            
            // Failed state
            TaskDetailCard(task: MockImportTask.failed)
            
            // Idle state
            TaskDetailCard(task: MockImportTask.idle)
            
            // Cancelled state
            TaskDetailCard(task: MockImportTask.cancelled)
        }
        .padding()
    }
    .background(Color.background)
}

#Preview("Single Running State") {
    TaskDetailCard(task: MockImportTask.running)
        .padding()
        .background(Color.background)
}

#Preview("Single Completed State") {
    TaskDetailCard(task: MockImportTask.completed)
        .padding()
        .background(Color.background)
}


struct MockImportTask {
    static let running: ImportTask = {
        let mockMedia = (0..<50).map { index in
            CleartextMedia(source: .data(Data()), mediaType: .photo, id: "IMG_123\(index).HEIC")
        }
        var task = ImportTask(
            id: "12345678-1234-1234-1234-123456789abc",
            media: mockMedia,
            albumId: "test-album",
            assetIdentifiers: Array(repeating: "asset-id", count: 50)
        )
        task.progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: 15,
            totalFiles: 50,
            currentFileProgress: 0.6,
            overallProgress: 0.3,
            currentFileName: "IMG_1234.HEIC",
            state: .running,
            estimatedTimeRemaining: TimeInterval(420) // 7 minutes
        )
        return task
    }()
    
    static let paused: ImportTask = {
        let mockMedia = (0..<25).map { index in
            CleartextMedia(source: .data(Data()), mediaType: .photo, id: "IMG_567\(index).jpeg")
        }
        var task = ImportTask(
            id: "87654321-4321-4321-4321-cba987654321",
            media: mockMedia,
            albumId: "test-album",
            assetIdentifiers: Array(repeating: "asset-id", count: 25)
        )
        task.progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: 8,
            totalFiles: 25,
            currentFileProgress: 0.5,
            overallProgress: 0.32,
            currentFileName: "IMG_5678.jpeg",
            state: .paused,
            estimatedTimeRemaining: TimeInterval(300) // 5 minutes
        )
        return task
    }()
    
    static let completed: ImportTask = {
        let mockMedia = (0..<100).map { index in
            CleartextMedia(source: .data(Data()), mediaType: .video, id: "IMG_999\(index).mov")
        }
        var task = ImportTask(
            id: "abcdef12-3456-7890-abcd-ef1234567890",
            media: mockMedia,
            albumId: "test-album",
            assetIdentifiers: Array(repeating: "asset-id", count: 100)
        )
        task.progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: 99,
            totalFiles: 100,
            currentFileProgress: 1.0,
            overallProgress: 1.0,
            currentFileName: "IMG_9999.mov",
            state: .completed,
            estimatedTimeRemaining: nil
        )
        return task
    }()
    
    static let failed: ImportTask = {
        let mockMedia = (0..<75).map { index in
            CleartextMedia(source: .data(Data()), mediaType: .photo, id: "IMG_000\(index).raw")
        }
        var task = ImportTask(
            id: "fedcba09-8765-4321-fedc-ba0987654321",
            media: mockMedia,
            albumId: "test-album",
            assetIdentifiers: Array(repeating: "asset-id", count: 75)
        )
        task.progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: 5,
            totalFiles: 75,
            currentFileProgress: 0.1,
            overallProgress: 0.067,
            currentFileName: "IMG_0001.raw",
            state: .failed(BackgroundImportError.taskNotFound),
            estimatedTimeRemaining: nil
        )
        return task
    }()
    
    static let idle: ImportTask = {
        let mockMedia = (0..<30).map { index in
            CleartextMedia(source: .data(Data()), mediaType: .photo, id: "IMG_111\(index).jpg")
        }
        var task = ImportTask(
            id: "11111111-2222-3333-4444-555555555555",
            media: mockMedia,
            albumId: "test-album",
            assetIdentifiers: Array(repeating: "asset-id", count: 30)
        )
        task.progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: 0,
            totalFiles: 30,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
        return task
    }()
    
    static let cancelled: ImportTask = {
        let mockMedia = (0..<40).map { index in
            CleartextMedia(source: .data(Data()), mediaType: .photo, id: "IMG_246\(index).png")
        }
        var task = ImportTask(
            id: "99999999-8888-7777-6666-555555555555",
            media: mockMedia,
            albumId: "test-album",
            assetIdentifiers: Array(repeating: "asset-id", count: 40)
        )
        task.progress = ImportProgressUpdate(
            taskId: task.id,
            currentFileIndex: 12,
            totalFiles: 40,
            currentFileProgress: 0.3,
            overallProgress: 0.3,
            currentFileName: "IMG_2468.png",
            state: .cancelled,
            estimatedTimeRemaining: nil
        )
        return task
    }()
} 
