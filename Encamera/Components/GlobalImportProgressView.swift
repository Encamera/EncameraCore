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
    
    var body: some View {
        if importManager.isImporting || !importManager.currentTasks.isEmpty {
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

struct ImportTaskDetailsView: View {
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(importManager.currentTasks, id: \.id) { task in
                        TaskDetailCard(task: task)
                    }
                }
                .padding()
            }
            .navigationTitle("Import Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear All") {
                        importManager.removeCompletedTasks()
                    }
                    .disabled(importManager.currentTasks.isEmpty)
                }
            }
        }
    }
}

struct TaskDetailCard: View {
    let task: ImportTask
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    
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
            HStack(spacing: 12) {
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
                    
                default:
                    EmptyView()
                }
                
                Button("Cancel") {
                    importManager.cancelImport(taskId: task.id)
                }
                .secondaryButton()
                
                Spacer()
            }
        }
        .padding()
        .background(Color.inputFieldBackgroundColor)
        .cornerRadius(12)
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
