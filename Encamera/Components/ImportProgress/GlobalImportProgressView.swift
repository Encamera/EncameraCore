import SwiftUI
import EncameraCore
import Combine
import Photos

struct GlobalImportProgressView: View {
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    @StateObject private var deletionManager = PhotoDeletionManager()
    @State private var showTaskDetails = false
    @State private var showDeleteConfirmation = false
    @Binding var showProgressView: Bool
    @State private var lastActiveImportSession: String? = nil
    @State private var dismissalSecondsRemaining: Int? = nil
    @State private var dismissalTimer: Timer? = nil

    var body: some View {
        Group {
            mainContent
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
            .onDisappear {
                // When leaving the view, mark as dismissed to prevent reappearing
                // until there's a new import session
                handleViewDisappear()
            }
    }

    private var progressCardWithInteractions: some View {
        progressCard
            .onTapGesture {
                // Cancel countdown if user taps to view details
                cancelDismissalCountdown()
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

    // Task filtering helpers
    private var activeTasks: [ImportTask] {
        importManager.currentTasks.filter { task in
            task.state == .running || task.state == .paused
        }
    }

    private var runningTasks: [ImportTask] {
        importManager.currentTasks.filter { $0.state == .running }
    }

    private var pausedTasks: [ImportTask] {
        importManager.currentTasks.filter { $0.state == .paused }
    }

    private var completedTasks: [ImportTask] {
        importManager.currentTasks.filter { $0.state == .completed }
    }

    // State helpers
    private var isCompleted: Bool {
        !importManager.isImporting && !completedTasks.isEmpty
    }

    private var isPaused: Bool {
        !pausedTasks.isEmpty
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
        if let remainingSeconds = dismissalSecondsRemaining {
            // Show countdown progress (5 seconds total, so progress = remaining/5)
            return Double(5 - remainingSeconds) / 5.0
        } else if isCompleted {
            return 1.0 // Show 100% when completed
        } else {
            return importManager.overallProgress
        }
    }

    private var statusText: String {
        if let remainingSeconds = dismissalSecondsRemaining {
            return "Dismissing in \(remainingSeconds) second\(remainingSeconds == 1 ? "" : "s")"
        } else if !completedTasks.isEmpty && activeTasks.isEmpty {
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
        for task in runningTasks {
            importManager.pauseImport(taskId: task.id)
        }
    }

    // MARK: - Action Functions

    private func handleActionButtonTap() {
        // Cancel countdown if user interacts with the action button
        cancelDismissalCountdown()
        
        if isCompleted {
            showDeleteConfirmation = true
        } else if isPaused {
            resumePausedTasks()
        } else {
            pauseCurrentTask()
        }
    }

    private func resumePausedTasks() {
        for task in pausedTasks {
            Task {
                try? await importManager.resumeImport(taskId: task.id)
            }
        }
    }

    private func deleteAllCompletedTaskPhotos() async {
        let allAssetIdentifiers = completedTasks.flatMap { $0.assetIdentifiers }

        await deletionManager.deletePhotos(assetIdentifiers: allAssetIdentifiers)

        // Remove completed tasks after successful deletion
        for task in completedTasks {
            importManager.cancelImport(taskId: task.id)
        }

        // If no tasks remain after deletion, clear session tracking
        if importManager.currentTasks.filter({ $0.state != .completed }).isEmpty {
            lastActiveImportSession = nil
        }
    }

    private func handleImportStateChange(isImporting: Bool) {
        if !isImporting && !completedTasks.isEmpty && showProgressView {
            // Start countdown timer for auto-dismiss
            startDismissalCountdown()
        } else if isImporting {
            // Cancel any ongoing dismissal countdown if import starts again
            cancelDismissalCountdown()
        }
    }

    private func handleTasksChange(tasks: [ImportTask]) {
        let currentRunningTasks = tasks.filter { $0.state == .running }

        if !currentRunningTasks.isEmpty {
            let currentSessionId = currentRunningTasks.first?.id

            // If this is a new session, reset dismissal state to ensure visibility
            if lastActiveImportSession != currentSessionId {
                lastActiveImportSession = currentSessionId
                showProgressView = false
            }
        }

        // If no tasks remain, clear the session tracking
        if tasks.isEmpty {
            lastActiveImportSession = nil
        }
    }

    private func handleViewDisappear() {
        // When navigating away and all tasks are completed, mark as dismissed
        if !importManager.isImporting &&
            !completedTasks.isEmpty &&
            importManager.currentTasks.allSatisfy({ $0.state == .completed }) {
            cancelDismissalCountdown()
            withAnimation(.easeOut(duration: 0.5)) {
                showProgressView = false
            }
        }
    }
    
    // MARK: - Dismissal Countdown Functions
    
    private func startDismissalCountdown() {
        cancelDismissalCountdown() // Cancel any existing timer
        dismissalSecondsRemaining = 5
        
        dismissalTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                if let remaining = self.dismissalSecondsRemaining, remaining > 0 {
                    self.dismissalSecondsRemaining = remaining - 1
                } else {
                    // Countdown finished, dismiss the view
                    timer.invalidate()
                    self.dismissalTimer = nil
                    self.dismissalSecondsRemaining = nil
                    
                    withAnimation(.easeOut(duration: 0.8)) {
                        self.showProgressView = false
                    }
                }
            }
        }
    }
    
    private func cancelDismissalCountdown() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        dismissalSecondsRemaining = nil
    }

}
