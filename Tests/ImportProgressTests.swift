import XCTest
@testable import Encamera
@testable import EncameraCore

@MainActor
class ImportProgressTests: XCTestCase {
    
    var importManager: BackgroundMediaImportManager!
    
    override func setUp() async throws {
        try await super.setUp()
        importManager = BackgroundMediaImportManager.shared
        // Clear any existing tasks
        importManager.currentTasks.removeAll()
    }
    
    override func tearDown() async throws {
        importManager.currentTasks.removeAll()
        try await super.tearDown()
    }
    
    func testCompletedTaskShowsCorrectProgress() async throws {
        // Given: Create a mock import task with 6 files
        let mockMedia = (0..<6).map { index in
            CleartextMedia(source: .data(Data()), mediaType: .photo, id: "file\(index)")
        }
        let task = ImportTask(media: mockMedia, albumId: "test-album")
        
        // When: Add the task and mark it as completed
        importManager.currentTasks.append(task)
        if let index = importManager.currentTasks.firstIndex(where: { $0.id == task.id }) {
            importManager.currentTasks[index].state = .completed
            importManager.currentTasks[index].progress = ImportProgressUpdate(
                taskId: task.id,
                currentFileIndex: 5,  // Last file index (0-based)
                totalFiles: 6,
                currentFileProgress: 1.0,
                overallProgress: 1.0,
                currentFileName: nil,
                state: .completed,
                estimatedTimeRemaining: 0
            )
        }
        
        // Then: Verify the progress is correct
        let completedTask = importManager.currentTasks.first { $0.id == task.id }
        XCTAssertNotNil(completedTask)
        XCTAssertEqual(completedTask?.state, .completed)
        XCTAssertEqual(completedTask?.progress.overallProgress, 1.0)
        XCTAssertEqual(completedTask?.progress.currentFileIndex, 5)
        XCTAssertEqual(completedTask?.progress.totalFiles, 6)
        XCTAssertEqual(completedTask?.progress.currentFileProgress, 1.0)
    }
    
    func testProgressCalculationDuringImport() async throws {
        // Given: Create a mock import task with 10 files
        let mockMedia = (0..<10).map { index in
            CleartextMedia(source: .data(Data()), mediaType: .photo, id: "file\(index)")
        }
        let task = ImportTask(media: mockMedia, albumId: "test-album")
        
        // When: Simulate progress at different stages
        importManager.currentTasks.append(task)
        
        // Test 1: Processing file 3 of 10 at 50% progress
        if let index = importManager.currentTasks.firstIndex(where: { $0.id == task.id }) {
            let processedFiles = 2  // Files 0, 1 are done
            let currentFileProgress = 0.5
            let overallProgress = (Double(processedFiles) + currentFileProgress) / Double(task.media.count)
            
            importManager.currentTasks[index].progress = ImportProgressUpdate(
                taskId: task.id,
                currentFileIndex: 2,  // Processing file at index 2
                totalFiles: 10,
                currentFileProgress: currentFileProgress,
                overallProgress: overallProgress,
                currentFileName: "file2",
                state: .running,
                estimatedTimeRemaining: nil
            )
            
            // Then: Verify the progress calculation
            XCTAssertEqual(overallProgress, 0.25, accuracy: 0.001)  // (2 + 0.5) / 10 = 0.25
            XCTAssertEqual(importManager.currentTasks[index].progress.currentFileIndex, 2)
        }
        
        // Test 2: All files processed
        if let index = importManager.currentTasks.firstIndex(where: { $0.id == task.id }) {
            let processedFiles = 10
            let overallProgress = Double(processedFiles) / Double(task.media.count)
            
            importManager.currentTasks[index].progress = ImportProgressUpdate(
                taskId: task.id,
                currentFileIndex: 9,  // Last file
                totalFiles: 10,
                currentFileProgress: 1.0,
                overallProgress: overallProgress,
                currentFileName: nil,
                state: .completed,
                estimatedTimeRemaining: 0
            )
            
            // Then: Verify complete progress
            XCTAssertEqual(overallProgress, 1.0)
            XCTAssertEqual(importManager.currentTasks[index].progress.currentFileIndex, 9)
        }
    }
    
    func testStatusTextForDifferentStates() async throws {
        // Test helper to create GlobalImportProgressView's statusText logic
        func getStatusText(for tasks: [ImportTask]) -> String {
            let activeTasks = tasks.filter { task in
                switch task.state {
                case .running, .paused:
                    return true
                default:
                    return false
                }
            }
            
            let completedTasks = tasks.filter { task in
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
        
        // Test 1: Completed task
        let completedTask = ImportTask(media: [CleartextMedia(source: .data(Data()), mediaType: .photo, id: "test")], albumId: "test")
        var tasks = [completedTask]
        if let index = tasks.firstIndex(where: { $0.id == completedTask.id }) {
            tasks[index].state = .completed
            tasks[index].progress = ImportProgressUpdate(
                taskId: tasks[index].id,
                currentFileIndex: 0,
                totalFiles: 1,
                currentFileProgress: 1.0,
                overallProgress: 1.0,
                currentFileName: nil,
                state: .completed,
                estimatedTimeRemaining: 0
            )
        }
        
        XCTAssertEqual(getStatusText(for: tasks), "Import completed")
        
        // Test 2: Running task showing progress
        let runningTask = ImportTask(media: Array(repeating: CleartextMedia(source: .data(Data()), mediaType: .photo, id: UUID().uuidString), count: 5), albumId: "test")
        var runningTasks = [runningTask]
        if let index = runningTasks.firstIndex(where: { $0.id == runningTask.id }) {
            runningTasks[index].state = .running
            runningTasks[index].progress = ImportProgressUpdate(
                taskId: runningTasks[index].id,
                currentFileIndex: 2,  // Processing 3rd file (0-based index)
                totalFiles: 5,
                currentFileProgress: 0.5,
                overallProgress: 0.5,
                currentFileName: "file3",
                state: .running,
                estimatedTimeRemaining: nil
            )
        }
        
        XCTAssertEqual(getStatusText(for: runningTasks), "Importing 3 of 5")
        
        // Test 3: Multiple running tasks
        let runningTask2 = ImportTask(media: Array(repeating: CleartextMedia(source: .data(Data()), mediaType: .photo, id: UUID().uuidString), count: 3), albumId: "test")
        var multipleTasks = runningTasks
        multipleTasks.append(runningTask2)
        if let index = multipleTasks.firstIndex(where: { $0.id == runningTask2.id }) {
            multipleTasks[index].state = .running
        }
        
        XCTAssertEqual(getStatusText(for: multipleTasks), "Importing 2 batches")
    }
} 