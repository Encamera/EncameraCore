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
    @State private var isDismissed = false
    @State private var lastActiveImportSession: String? = nil
    
    var body: some View {
        Group {
            if shouldShowProgressView && !isDismissed {
                mainContent
            }
        }
    }
    
    // MARK: - Body Subcomponents
    
    private var mainContent: some View {
        progressCardWithInteractions
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
            .onChange(of: importManager.currentTasks) { _, tasks in
                handleTasksChange(tasks: tasks)
            }
            .onAppear {
                // Always reset UI dismissal state when view appears
                // This ensures the progress view shows properly when navigating back to the view
                resetUIState()
            }
            .onDisappear {
                // When leaving the view, mark as dismissed to prevent reappearing
                // until there's a new import session
                handleViewDisappear()
            }
    }
    
    private var progressCardWithInteractions: some View {
        progressCard
            .onTapGesture {
                showTaskDetails = true
            }
    }
    

    
    private var progressCard: some View {
        VStack(spacing: 0) {
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
        
        // If no tasks remain after deletion, clear session tracking and hide
        if importManager.currentTasks.filter({ $0.state != .completed }).isEmpty {
            lastActiveImportSession = nil
            withAnimation(.easeOut(duration: 0.3)) {
                hideAfterCompletion = true
            }
        }
    }
    
    private func handleImportStateChange(isImporting: Bool) {
        if !isImporting {
            let completedTasks = importManager.currentTasks.filter { $0.state == .completed }
            
            // Auto-dismiss after 5 seconds when tasks complete (only if not manually dismissed)
            if !completedTasks.isEmpty && !hideAfterCompletion && !isDismissed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        hideAfterCompletion = true
                    }
                }
            }
        } else {
            // Reset hide flag if importing starts again
            hideAfterCompletion = false
        }
    }
    
    private func handleTasksChange(tasks: [ImportTask]) {
        // Check if this is a new import session by looking for running tasks
        let runningTasks = tasks.filter { $0.state == .running }
        
        if !runningTasks.isEmpty {
            let currentSessionId = runningTasks.first?.id
            
            // If this is a new session, reset all dismissal state to ensure visibility
            if lastActiveImportSession != currentSessionId {
                lastActiveImportSession = currentSessionId
                resetDismissalState()
                hideAfterCompletion = false
            }
        }
        
        // If no tasks remain, clear the session tracking and allow auto-hide
        if tasks.isEmpty {
            lastActiveImportSession = nil
            hideAfterCompletion = false
        }
    }
    
    private func resetDismissalState() {
        isDismissed = false
    }
    
    private func resetUIState() {
        // Reset UI-specific dismissal state when view appears
        // This allows the progress view to show again if there are active/completed tasks
        isDismissed = false
        
        // If there are no active imports and only completed tasks, don't auto-hide
        // Let the user see the completed state until they manually dismiss or navigate away
        if !importManager.isImporting && !importManager.currentTasks.isEmpty {
            let hasActiveOrCompletedTasks = importManager.currentTasks.contains { task in
                task.state == .running || task.state == .paused || task.state == .completed
            }
            if hasActiveOrCompletedTasks {
                hideAfterCompletion = false
            }
        }
    }
    
    private func handleViewDisappear() {
        // When navigating away from the view, mark as dismissed only if imports are completed
        // This prevents the progress view from reappearing when navigating back
        if !importManager.isImporting {
            let completedTasks = importManager.currentTasks.filter { $0.state == .completed }
            if !completedTasks.isEmpty && importManager.currentTasks.allSatisfy({ $0.state == .completed }) {
                // All tasks are completed, mark as dismissed to prevent showing on next view appearance
                isDismissed = true
            }
        }
    }

}
