import SwiftUI
import EncameraCore
import Combine
import Photos

// MARK: - View Model

@MainActor
class GlobalImportProgressViewModel: ObservableObject {
    @Published var showDeleteConfirmation = false
    @Published var displayedProgress: CircularProgressDisplayMode
    @Published var statusText: String = L10n.GlobalImportProgress.noActiveImports
    @Published var estimatedTimeRemaining: String? = nil
    private let countdown: Int = 5

    var importManager = BackgroundMediaImportManager.shared
    @Published var completedTasks: [ImportTask] = []
    @Published var isCompleted: Bool = false
    var deleteEnabled: Bool
    @Published var activeTasks: [ImportTask] = []

    let deletionManager = PhotoDeletionManager()
    private var dismissalTimer: Timer? = nil
    private var lastActiveImportSession: String? = nil
    private var cancellables = Set<AnyCancellable>()
    private var lastKnownETA: String? = nil


    init(deleteEnabled: Bool,
         displayedProgress: CircularProgressDisplayMode = .percentage(value: 0.0),
         isCompleted: Bool = false,
         completedTasks: [ImportTask] = [],
         activeTasks: [ImportTask] = []
    ) {
        self.completedTasks = completedTasks
        self.activeTasks = activeTasks
        self.isCompleted = isCompleted
        self.displayedProgress = displayedProgress
        self.deleteEnabled = deleteEnabled
        
        // Initialize status text
        updateStatusText()

        // Smooth progress updates with debouncing
        self.importManager.$overallProgress
            .dropFirst()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .filter({$0 > 0.0})
            .sink { [weak self] value in
                guard let self = self else { return }

                self.displayedProgress = .percentage(value: value)
            }.store(in: &cancellables)

        self.importManager.$isImporting.dropFirst().sink { [weak self] isImporting in
            self?.isCompleted = !isImporting
            self?.updateStatusText()
        }.store(in: &cancellables)

        self.importManager.$currentTasks.dropFirst().sink { [weak self] tasks in
            guard let self = self else { return }
            let completed = tasks.filter { $0.state == .completed }
            let active = tasks.filter { $0.state == .running }
            self.completedTasks = completed
            self.activeTasks = active
            self.updateStatusText()
            self.updateEstimatedTimeRemaining()
        }.store(in: &cancellables)
    }
    
    // MARK: - Computed Properties
    
    var actionButtonText: String {
        if isCompleted {
            return completedTasks.isEmpty ? L10n.cancel : L10n.delete
        } else {
            return L10n.cancel
        }
    }

    /// Controls visibility of the action button.
    /// - When importing: show the Cancel button if `deleteEnabled` is true (existing behavior).
    /// - When completed successfully: show Delete if `deleteEnabled` is true and there are completed tasks.
    /// - When cancelled (no completed tasks): hide the button entirely.
    var shouldHideActionButton: Bool {
        if isCompleted {
            // Hide when cancelled (no completed tasks), or when delete is disabled
            return completedTasks.isEmpty || !deleteEnabled
        } else {
            // Preserve existing behavior for in-progress state
            return !deleteEnabled
        }
    }

    // MARK: - Update Methods
    
    private func updateStatusText() {
        var retVal: String

        if !completedTasks.isEmpty && activeTasks.isEmpty {
            retVal = L10n.GlobalImportProgress.importCompleted
        } else if isCompleted && activeTasks.isEmpty && !completedTasks.isEmpty {
            retVal = L10n.GlobalImportProgress.importCompleted
        } else if isCompleted && activeTasks.isEmpty {
            retVal = L10n.GlobalImportProgress.importStopped
        } else if activeTasks.isEmpty {
            retVal = L10n.GlobalImportProgress.noActiveImports
        } else if activeTasks.count == 1 {
            let task = activeTasks.first!
            retVal = L10n.GlobalImportProgress.importingProgress(task.progress.currentFileIndex + 1, task.progress.totalFiles)
        } else {
            retVal = L10n.GlobalImportProgress.importingBatches(activeTasks.count)
        }

        statusText = retVal
    }
    private func updateEstimatedTimeRemaining() {
        guard let task = activeTasks.first,
              let eta = task.progress.estimatedTimeRemaining else {
            // Keep last known ETA if no new value is available
            if activeTasks.isEmpty {
                estimatedTimeRemaining = nil
                lastKnownETA = nil
            }
            return
        }

        let newETA: String
        if eta < 60 {
            newETA = "\(Int(eta))s \(L10n.GlobalImportProgress.remaining)"
        } else if eta < 3600 {
            newETA = "\(Int(eta / 60))m \(L10n.GlobalImportProgress.remaining)"
        } else {
            newETA = "\(Int(eta / 3600))h \(L10n.GlobalImportProgress.remaining)"
        }
        
        estimatedTimeRemaining = newETA
        lastKnownETA = newETA
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
        for task in activeTasks {
            importManager.cancelImport(taskId: task.id)
        }
    }
    
    func handleActionButtonTap() {
        if isCompleted {
            // Only allow delete when there are completed tasks (not a cancelled import)
            guard !completedTasks.isEmpty else { return }
            // Cancel dismissal timer when showing delete confirmation
            cancelDismissalTimer()
            showDeleteConfirmation = true
        } else {
            stopCurrentTask()
        }
    }
    
    private func cancelDismissalTimer() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
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
            // If we have completed tasks, show 100% before starting countdown
            if !completedTasks.isEmpty {
                displayedProgress = .percentage(value: 1.0)
                // Delay countdown start to show completion state
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startDismissalCountdown(showProgressView: showProgressView)
                }
            } else {
                // Start countdown timer for auto-dismiss when import stops (cancelled)
                startDismissalCountdown(showProgressView: showProgressView)
            }
        }
    }

    func handleTasksChange(tasks: [ImportTask], showProgressView: Binding<Bool>) {
        let currentRunningTasks = tasks.filter { $0.state == .running }

        if !currentRunningTasks.isEmpty {
            let currentSessionId = currentRunningTasks.first?.id

            // If this is a new session, reset dismissal state to ensure visibility
            if lastActiveImportSession != currentSessionId {
                lastActiveImportSession = currentSessionId
                withAnimation(.easeOut(duration: 1.0)) {
                    showProgressView.wrappedValue = false
                }
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
            // Wrap the dismissal in animation
            withAnimation(.easeOut(duration: 1.0)) {
                showProgressView.wrappedValue = false
            }
            // Clear all tasks and reset state when view is dismissed
            resetAllState()
        }
    }
    
    func resetAllState() {
        // Cancel any dismissal timer
        cancelDismissalTimer()
        
        // Clear the import manager
        importManager.clearAllTasks()
        
        // Reset all local state
        completedTasks.removeAll()
        activeTasks.removeAll()
        isCompleted = false
        displayedProgress = .percentage(value: 0.0)
        statusText = L10n.GlobalImportProgress.noActiveImports
        estimatedTimeRemaining = nil
        lastKnownETA = nil
        lastActiveImportSession = nil
    }
    
    func startDismissalCountdown(showProgressView: Binding<Bool>) {
        // Don't start countdown if delete confirmation is showing
        guard !showDeleteConfirmation else { return }
        
        var currentCountdown = countdown

        dismissalTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { 
                timer.invalidate()
                return 
            }
            
            DispatchQueue.main.async {
                currentCountdown -= 1
                
                if currentCountdown <= 0 {
                    // Countdown finished, dismiss the view
                    self.cancelDismissalTimer()
                    
                    // Wrap the dismissal in animation
                    withAnimation(.easeOut(duration: 1.5)) {
                        showProgressView.wrappedValue = false
                    }
                } else {
                    // Update countdown display
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
    @State private var dragOffset: CGFloat = 0
    
    private let swipeThreshold: CGFloat = 100

    var body: some View {
        Group {
            mainContent
        }
        // Remove internal transition to avoid conflicts with parent transition
        .offset(y: max(0, dragOffset)) // Only allow downward movement
        // .simultaneousGesture(
        //         DragGesture()
        //             .onChanged { value in
        //                 // Only track downward drags that are significant
        //                 if value.translation.height > 10 {
        //                     dragOffset = value.translation.height
        //                 }
        //             }
        //             .onEnded { value in
        //                 if value.translation.height > swipeThreshold {
        //                     // Swipe down threshold reached, dismiss the view
        //                     withAnimation(.easeOut(duration: 0.5)) {
        //                         showProgressView = false
        //                     }
        //                 } else {
        //                     // Snap back to original position
        //                     withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
        //                         dragOffset = 0
        //                     }
        //                 }
        //             }
        //     )
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
            .onChange(of: showProgressView) { _, isShowing in
                if !isShowing {
                    // Reset drag offset when view is dismissed
                    dragOffset = 0
                    // Reset all state when view is hidden
                    viewModel.resetAllState()
                }
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
                    withAnimation(.easeOut(duration: 1.0)) {
                        showProgressView = false
                    }
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
                            .lineLimit(1, reservesSpace: true)
                    }
                }

                Spacer()

                // Action button
                Button(action: viewModel.handleActionButtonTap) {
                    Text(viewModel.actionButtonText)
                }
                .textButton()
                .if(viewModel.shouldHideActionButton) { view in
                    view.hidden()
                }
                .padding(.trailing, 5)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

}

// MARK: - Previews

#Preview("All States") {
    @Previewable @State var showProgressView = true
    
    ScrollView {
        VStack(spacing: 20) {
            // Active Import - Single Task (simulated with 1 active task)
            VStack(alignment: .leading) {
                Text("Active Import - Single Task")
                    .font(.headline)
                GlobalImportProgressView(
                    viewModel: .init(
                        deleteEnabled: true,
                        displayedProgress: .percentage(value: 0.65),
                        isCompleted: false,
                        completedTasks: [],
                        activeTasks: [MockImportTask.singleRunning]
                    ),
                    showProgressView: $showProgressView
                )
            }
            
            // Active Import - Multiple Tasks
            VStack(alignment: .leading) {
                Text("Active Import - Multiple Tasks")
                    .font(.headline)
                GlobalImportProgressView(
                    viewModel: .init(
                        deleteEnabled: true,
                        displayedProgress: .percentage(value: 0.28),
                        isCompleted: false,
                        completedTasks: [],
                        activeTasks: [MockImportTask.multipleRunning1, MockImportTask.multipleRunning2]
                    ),
                    showProgressView: $showProgressView
                )
            }
            
            // Import Completed - With Delete Option
            VStack(alignment: .leading) {
                Text("Import Completed - With Delete Option")
                    .font(.headline)
                GlobalImportProgressView(
                    viewModel: .init(
                        deleteEnabled: true,
                        displayedProgress: .percentage(value: 1.0),
                        isCompleted: true,
                        completedTasks: [MockImportTask.completed],
                        activeTasks: []
                    ),
                    showProgressView: $showProgressView
                )
            }
            
            // Import Completed - Delete Disabled
            VStack(alignment: .leading) {
                Text("Import Completed - Delete Disabled")
                    .font(.headline)
                GlobalImportProgressView(
                    viewModel: .init(
                        deleteEnabled: false,
                        displayedProgress: .percentage(value: 1.0),
                        isCompleted: true,
                        completedTasks: [MockImportTask.completed],
                        activeTasks: []
                    ),
                    showProgressView: $showProgressView
                )
            }
            
            // Countdown State
            VStack(alignment: .leading) {
                Text("Countdown State (Auto-dismiss)")
                    .font(.headline)
                GlobalImportProgressView(
                    viewModel: .init(
                        deleteEnabled: true,
                        displayedProgress: .countdown(initial: 5, value: 3),
                        isCompleted: true,
                        completedTasks: [MockImportTask.completed],
                        activeTasks: []
                    ),
                    showProgressView: $showProgressView
                )
            }
            
            // No Active Tasks
            VStack(alignment: .leading) {
                Text("No Active Imports")
                    .font(.headline)
                GlobalImportProgressView(
                    viewModel: .init(
                        deleteEnabled: true,
                        displayedProgress: .percentage(value: 0.0),
                        isCompleted: false,
                        completedTasks: [],
                        activeTasks: []
                    ),
                    showProgressView: $showProgressView
                )
            }
            
            // Import Stopped
            VStack(alignment: .leading) {
                Text("Import Stopped")
                    .font(.headline)
                GlobalImportProgressView(
                    viewModel: .init(
                        deleteEnabled: true,
                        displayedProgress: .percentage(value: 0.4),
                        isCompleted: false,
                        completedTasks: [],
                        activeTasks: []
                    ),
                    showProgressView: $showProgressView
                )
            }
        }
        .padding()
    }
//    .background(Color.gray.opacity(0.1))
}

// MARK: - Mock Data

extension ImportTask {
    static var mockMedia: CleartextMedia {
        CleartextMedia(source: URL(fileURLWithPath: "/tmp/test.jpg"))
    }
}
