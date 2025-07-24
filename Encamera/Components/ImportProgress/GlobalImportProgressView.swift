import SwiftUI
import EncameraCore
import Combine
import Photos

struct GlobalImportProgressView: View {
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    @State private var isExpanded = false
    @State private var showTaskDetails = false
    @State private var showPhotoAccessAlert = false
    @State private var taskIdForDeletion: String? = nil
    @State private var hideAfterCompletion = false
    
    var body: some View {
        if (importManager.isImporting || !importManager.currentTasks.isEmpty) && !hideAfterCompletion {
            VStack(spacing: 0) {
                // Compact progress bar
                if !isExpanded {
                    compactProgressView
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isExpanded = true
                            }
                        }
                } else {
                    // Expanded view with task details
                    expandedProgressView
                }
            }
            .background(Color.modalBackgroundColor)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
            .onChange(of: importManager.isImporting) { _, isImporting in
                // When importing stops, check if we should hide after completion
                if !isImporting {
                    let completedTasks = importManager.currentTasks.filter { task in
                        task.state == .completed
                    }
                    
                    // If we have completed tasks, start the hide timer
                    if !completedTasks.isEmpty && !hideAfterCompletion {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
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
        }
    }
    
    private var compactProgressView: some View {
        HStack(spacing: 12) {
            // Progress indicator
            if importManager.isImporting {
                ProgressView(value: importManager.overallProgress, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .actionYellowGreen))
                    .frame(height: 4)
            }

            // Status text
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .fontType(.pt12, weight: .medium)
                    .foregroundColor(.foregroundPrimary)
                
                if let eta = estimatedTimeRemaining {
                    Text(eta)
                        .fontType(.pt10)
                        .foregroundColor(.actionYellowGreen
)
                }
            }
            
            Spacer()
            
            // Control buttons
            HStack(spacing: 8) {
                if importManager.isImporting {
                    Button(action: pauseCurrentTask) {
                        Image(systemName: "pause.circle.fill")
                            .foregroundColor(.actionYellowGreen
)
                            .font(.system(size: 20))
                    }
                }
                
                Button(action: { showTaskDetails.toggle() }) {
                    Image(systemName: "ellipsis.circle.fill")
                        .foregroundColor(.actionYellowGreen
)
                        .font(.system(size: 20))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .sheet(isPresented: $showTaskDetails) {
            ImportTaskDetailsView()
        }
    }
    
    private var expandedProgressView: some View {
        VStack(spacing: 12) {
            // Header with collapse button
            HStack {
                Text("Import Progress")
                    .fontType(.pt16, weight: .semibold)
                    .foregroundColor(.foregroundPrimary)
                
                Spacer()
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isExpanded = false
                    }
                }) {
                    Image(systemName: "chevron.down")
                        .foregroundColor(.actionYellowGreen
)
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            // Progress details
            VStack(spacing: 8) {
                ForEach(importManager.currentTasks, id: \.id) { task in
                    TaskProgressRow(task: task)
                }
            }
            .padding(.horizontal, 16)
            
            // Action buttons
            HStack(spacing: 12) {
                if importManager.isImporting {
                    Button("Pause All") {
                        pauseAllTasks()
                    }
                    .primaryButton()
                    .frame(maxWidth: .infinity)
                }
                
                Button("Clear Completed") {
                    importManager.removeCompletedTasks()
                }
                .secondaryButton()
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
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
    
    private func pauseAllTasks() {
        for task in importManager.currentTasks {
            if task.state == .running {
                importManager.pauseImport(taskId: task.id)
            }
        }
    }
}
