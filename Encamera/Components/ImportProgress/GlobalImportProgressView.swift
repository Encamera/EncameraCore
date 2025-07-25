import SwiftUI
import EncameraCore
import Combine
import Photos

struct GlobalImportProgressView: View {
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    @StateObject private var deletionManager = PhotoDeletionManager()
    @State private var showTaskDetails = false
    @State private var showDeleteConfirmation = false
    @State private var hideAfterCompletion = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissed = false
    
    var body: some View {
        Group {
            if shouldShowProgressView && !isDismissed {
                progressCard
                    .offset(y: dragOffset)
                    .onTapGesture {
                        showTaskDetails = true
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if value.translation.height > 0 {
                                    dragOffset = value.translation.height
                                }
                            }
                            .onEnded { value in
                                if value.translation.height > 50 {
                                    // Dismiss if dragged down enough
                                    withAnimation(.easeOut(duration: 0.3)) {
                                        isDismissed = true
                                    }
                                } else {
                                    // Snap back
                                    withAnimation(.spring()) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
                    .background(Color.modalBackgroundColor)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .alert("Delete from Photo Library?", isPresented: $showDeleteConfirmation) {
                        Button("Delete", role: .destructive) {
                            Task {
                                await deleteAllCompletedTaskPhotos()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will delete all imported photos from your Photo Library.")
                    }
                    .alert("Photo Library Access Required", isPresented: $deletionManager.showPhotoAccessAlert) {
                        Button("Open Settings") {
                            deletionManager.openSettings()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Please grant full access to your photo library in Settings to delete imported photos.")
                    }
                    .onChange(of: importManager.isImporting) { _, isImporting in
                        handleImportStateChange(isImporting: isImporting)
                    }
                    .onAppear {
                        resetDismissalState()
                    }
            }
        }
    }
    
    private var progressCard: some View {
        VStack(spacing: 0) {
            // Dismissal knob (only show when completed)
            if isCompleted {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondaryElementColor.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)
            }
            
            HStack(spacing: 16) {
                // Circular progress indicator
                CircularProgressView(
                    progress: displayProgress,
                    lineWidth: 4,
                    size: 60
                )
                
                // Status text and details
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusText)
                        .fontType(.pt14, weight: .semibold)
                        .foregroundColor(.foregroundPrimary)
                    
                    if let eta = estimatedTimeRemaining {
                        Text(eta)
                            .fontType(.pt12)
                            .foregroundColor(.actionYellowGreen)
                    }
                }
                
                Spacer()
                
                // Action button
                Button(action: handleActionButtonTap) {
                    Image(actionButtonImageName)
                        .renderingMode(.template)
                        .foregroundColor(.actionYellowGreen)
                        .font(.system(size: 24))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showTaskDetails) {
            ImportTaskDetailsView()
        }
    }
    
    // MARK: - Computed Properties
    
    private var shouldShowProgressView: Bool {
        (importManager.isImporting || !importManager.currentTasks.isEmpty) && !hideAfterCompletion
    }
    
    private var isCompleted: Bool {
        !importManager.isImporting && !importManager.currentTasks.filter { 
            $0.state == .completed 
        }.isEmpty
    }
    
    private var isPaused: Bool {
        !importManager.currentTasks.filter { 
            $0.state == .paused 
        }.isEmpty
    }
    
    private var actionButtonImageName: String {
        if isCompleted {
            return "Trash"
        } else if isPaused {
            return "play.fill"
        } else {
            return "Pause"
        }
    }
    
    private var displayProgress: Double {
        if isCompleted {
            return 1.0 // Show 100% when completed
        } else {
            return importManager.overallProgress
        }
    }
    
    private var statusText: String {
        let activeTasks = importManager.currentTasks.filter { task in
            switch task.state {
            case .running, .paused:
                return true
            default:
                return false
            }
        }
        
        let completedTasks = importManager.currentTasks.filter { task in
            task.state == .completed
        }
        
        if !completedTasks.isEmpty && activeTasks.isEmpty {
            return "Import completed"
        } else if activeTasks.isEmpty {
            return "No active imports"
        } else if activeTasks.count == 1 {
            let task = activeTasks.first!
            return "Importing \(task.progress.currentFileIndex + 1) of \(task.progress.totalFiles)"
        } else {
            return "Importing \(activeTasks.count) batches"
        }
    }
    
    private var estimatedTimeRemaining: String? {
        let runningTasks = importManager.currentTasks.filter { $0.state == .running }
        guard let task = runningTasks.first,
              let eta = task.progress.estimatedTimeRemaining else {
            return nil
        }
        
        if eta < 60 {
            return "\(Int(eta))s remaining"
        } else if eta < 3600 {
            return "\(Int(eta / 60))m remaining"
        } else {
            return "\(Int(eta / 3600))h remaining"
        }
    }
    
    private func pauseCurrentTask() {
        let runningTasks = importManager.currentTasks.filter { $0.state == .running }
        for task in runningTasks {
            importManager.pauseImport(taskId: task.id)
        }
    }
    
    // MARK: - Action Functions
    
    private func handleActionButtonTap() {
        if isCompleted {
            showDeleteConfirmation = true
        } else if isPaused {
            resumePausedTasks()
        } else {
            pauseCurrentTask()
        }
    }
    
    private func resumePausedTasks() {
        let pausedTasks = importManager.currentTasks.filter { $0.state == .paused }
        for task in pausedTasks {
            Task {
                try? await importManager.resumeImport(taskId: task.id)
            }
        }
    }
    
    private func deleteAllCompletedTaskPhotos() async {
        let completedTasks = importManager.currentTasks.filter { $0.state == .completed }
        let allAssetIdentifiers = completedTasks.flatMap { $0.assetIdentifiers }
        
        await deletionManager.deletePhotos(assetIdentifiers: allAssetIdentifiers)
        
        // Remove completed tasks after successful deletion
        for task in completedTasks {
            importManager.cancelImport(taskId: task.id)
        }
    }
    
    private func handleImportStateChange(isImporting: Bool) {
        if !isImporting {
            let completedTasks = importManager.currentTasks.filter { $0.state == .completed }
            
            // Auto-dismiss after 5 seconds when tasks complete
            if !completedTasks.isEmpty && !hideAfterCompletion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        hideAfterCompletion = true
                    }
                    
                    // Reset after hiding so it can show again for future imports
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        hideAfterCompletion = false
                    }
                }
            }
        } else {
            // Reset hide flag if importing starts again
            hideAfterCompletion = false
        }
    }
    
    private func resetDismissalState() {
        isDismissed = false
        dragOffset = 0
    }

}
