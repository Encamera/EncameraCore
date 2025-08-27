import SwiftUI
import EncameraCore
import Combine
import Photos

// MARK: - View Model

@MainActor
class GlobalImportProgressViewModel: ObservableObject {
    @Published var showDeleteConfirmation = false
    @Published var displayedProgress: CircularProgressDisplayMode
    private let countdown: Int = 5

    var importManager = BackgroundMediaImportManager.shared
    let deletionManager = PhotoDeletionManager()
    private var dismissalTimer: Timer? = nil
    private var lastActiveImportSession: String? = nil
    private var cancellables = Set<AnyCancellable>()
    private var deleteEnabled: Bool
    var isCountingDown: Bool {
        guard let dismissalTimer else {
            return false
        }
        return dismissalTimer.isValid
    }
    init(deleteEnabled: Bool) {
        self.displayedProgress = .percentage(value: 0.0)
        self.deleteEnabled = deleteEnabled
        self.importManager.$overallProgress.dropFirst().sink { [weak self] value in
            self?.displayedProgress = .percentage(value: value)

        }.store(in: &cancellables)
    }
    
    // MARK: - Computed Properties
    
    var activeTasks: [ImportTask] {
        importManager.currentTasks.filter { task in
            task.state == .running
        }
    }
    
    var runningTasks: [ImportTask] {
        importManager.currentTasks.filter { $0.state == .running }
    }
    
    var completedTasks: [ImportTask] {
        importManager.currentTasks.filter { $0.state == .completed }
    }
    
    var isCompleted: Bool {
        !importManager.isImporting && !completedTasks.isEmpty
    }
    
    var actionButtonImageName: String {
        if isCompleted {
            return "trash.fill"
        } else {
            return "stop.fill"
        }
    }
    

    var statusText: String {
        if !completedTasks.isEmpty && activeTasks.isEmpty {
            return L10n.GlobalImportProgress.importCompleted
        } else if !importManager.isImporting && activeTasks.isEmpty && !completedTasks.isEmpty {
            return L10n.GlobalImportProgress.importCompleted
        } else if !importManager.isImporting && activeTasks.isEmpty {
            return L10n.GlobalImportProgress.importStopped
        } else if activeTasks.isEmpty {
            return L10n.GlobalImportProgress.noActiveImports
        } else if activeTasks.count == 1 {
            let task = activeTasks.first!
            return L10n.GlobalImportProgress.importingProgress(task.progress.currentFileIndex + 1, task.progress.totalFiles)
        } else {
            return L10n.GlobalImportProgress.importingBatches(activeTasks.count)
        }
    }
    
    var estimatedTimeRemaining: String? {
        guard let task = runningTasks.first,
              let eta = task.progress.estimatedTimeRemaining else {
            return nil
        }

        if eta < 60 {
            return "\(Int(eta))s \(L10n.GlobalImportProgress.remaining)"
        } else if eta < 3600 {
            return "\(Int(eta / 60))m \(L10n.GlobalImportProgress.remaining)"
        } else {
            return "\(Int(eta / 3600))h \(L10n.GlobalImportProgress.remaining)"
        }
    }
    
    // MARK: - Methods
    
    func calculateActualProgress() -> Double {
        guard !activeTasks.isEmpty else { return 0.0 }
        
        let totalProgress = activeTasks.reduce(into: 0.0) { sum, task in
            sum += task.progress.overallProgress
        }
        
        return totalProgress / Double(activeTasks.count)
    }
    
    func stopCurrentTask() {
        for task in runningTasks {
            importManager.cancelImport(taskId: task.id)
        }
    }
    
    func handleActionButtonTap() {

        if isCompleted {
            showDeleteConfirmation = true
        } else {
            stopCurrentTask()
        }
    }
    

    
    func deleteAllCompletedTaskPhotos() async {
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
    
    func handleImportStateChange(isImporting: Bool, showProgressView: Binding<Bool>) {
        if !isImporting && showProgressView.wrappedValue {
            // Start countdown timer for auto-dismiss when import stops (completed or cancelled)
            startDismissalCountdown(showProgressView: showProgressView)
        }
    }

    func handleTasksChange(tasks: [ImportTask], showProgressView: Binding<Bool>) {
        let currentRunningTasks = tasks.filter { $0.state == .running }

        if !currentRunningTasks.isEmpty {
            let currentSessionId = currentRunningTasks.first?.id

            // If this is a new session, reset dismissal state to ensure visibility
            if lastActiveImportSession != currentSessionId {
                lastActiveImportSession = currentSessionId
                showProgressView.wrappedValue = false
            }
        }
        // If no tasks remain, clear the session tracking
        if tasks.isEmpty {
            lastActiveImportSession = nil
        }
    }
    
    func handleViewDisappear(showProgressView: Binding<Bool>) {
        // When navigating away and import is not running, mark as dismissed
        if !importManager.isImporting {
            withAnimation(.easeOut(duration: 0.5)) {
                showProgressView.wrappedValue = false
            }
            // Clear all tasks and reset state when view is dismissed
            importManager.clearAllTasks()
        }
    }
    
    func startDismissalCountdown(showProgressView: Binding<Bool>) {
        displayedProgress = .countdown(initial: countdown, value: countdown)
        
        dismissalTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                guard case .countdown(_, let value) = self.displayedProgress else {
                    return
                }
                if value <= 0 {
                    // Countdown finished, dismiss the view
                    timer.invalidate()
                    self.dismissalTimer = nil

                    withAnimation(.easeOut(duration: 0.8)) {
                        showProgressView.wrappedValue = false
                    }
                }
            }
        }
    }
    
    // MARK: - Deinitializer
    
//    deinit {
//        cancelDismissalCountdown()
//    }
}

// MARK: - View

struct GlobalImportProgressView: View {
    @StateObject private var viewModel: GlobalImportProgressViewModel
    @Binding var showProgressView: Bool

    var body: some View {
        Group {
            mainContent
        }
    }

    init(viewModel: GlobalImportProgressViewModel, showProgressView: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _showProgressView = showProgressView
    }

    // MARK: - Body Subcomponents

    private var mainContent: some View {
        progressCardWithInteractions
            .background(Color.modalBackgroundColor)
            .cornerRadius(88)
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .alert(L10n.GlobalImportProgress.deleteFromPhotoLibraryAlert, isPresented: $viewModel.showDeleteConfirmation) {
                Button(L10n.delete, role: .destructive) {
                    Task {
                        await viewModel.deleteAllCompletedTaskPhotos()
                    }
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.GlobalImportProgress.deleteFromPhotoLibraryMessage)
            }
            .onChange(of: viewModel.importManager.isImporting) { _, isImporting in
                viewModel.handleImportStateChange(isImporting: isImporting, showProgressView: $showProgressView)
            }
            .onChange(of: viewModel.importManager.currentTasks) { _, tasks in
                viewModel.handleTasksChange(tasks: tasks, showProgressView: $showProgressView)
            }
            .onDisappear {
                // When leaving the view, mark as dismissed to prevent reappearing
                // until there's a new import session
                viewModel.handleViewDisappear(showProgressView: $showProgressView)
            }
    }

    private var progressCardWithInteractions: some View {
        progressCard
            .onTapGesture {
                if viewModel.isCompleted {
                    showProgressView = false
                }
            }
    }



    private var progressCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Circular progress indicator
                CircularProgressView(
                    lineWidth: 4,
                    size: 60,
                    displayMode: viewModel.displayedProgress,

                )

                // Status text and details
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.statusText)
                        .fontType(.pt14, weight: .semibold)
                        .foregroundColor(.foregroundPrimary)

                    if let eta = viewModel.estimatedTimeRemaining {
                        Text(eta)
                            .fontType(.pt12)
                            .foregroundColor(.actionYellowGreen)
                    }
                }

                Spacer()

                // Action button
                Button(action: viewModel.handleActionButtonTap) {
                    Image(systemName: viewModel.actionButtonImageName)
                        .renderingMode(.template)
                        .foregroundColor(.actionYellowGreen)
                        .font(.system(size: 24))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

}

// MARK: - Previews

#Preview("Active Import") {
    @Previewable @State var showProgressView = true
    
    GlobalImportProgressView(viewModel: .init(deleteEnabled: true), showProgressView: $showProgressView)
        .padding()
        .background(Color.gray.opacity(0.1))
}


