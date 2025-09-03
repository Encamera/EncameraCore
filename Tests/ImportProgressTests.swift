import XCTest
@testable import Encamera
@testable import EncameraCore

@MainActor
class ImportProgressTests: XCTestCase {
    
    // Helper class to test status text logic
    class TestableViewModel {
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
    }
    
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
        let task = ImportTask(media: mockMedia, albumId: "test-album", source: .photos)
        
        // When: Add the task and mark it as completed
        importManager.currentTasks.append(task)
        if let index = importManager.currentTasks.firstIndex(where: { $0.id == task.id }) {
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
        let task = ImportTask(media: mockMedia, albumId: "test-album", source: .photos)
        
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
        let viewModel = TestableViewModel()
        
        // Test for no active imports
        XCTAssertEqual(viewModel.getStatusText(for: []), "No active imports")
        
        // Test for completed tasks only
        var completedTask = ImportTask(media: [], albumId: "album1", source: .files)
        completedTask.progress.state = .completed
        XCTAssertEqual(viewModel.getStatusText(for: [completedTask]), "Import completed")
        
        // Test for single active task
        var activeTask = ImportTask(media: Array(repeating: CleartextMedia(source: .data(Data()), generateID: true), count: 10), albumId: "album1", source: .photos)
        activeTask.progress = ImportProgressUpdate(
            taskId: activeTask.id,
            currentFileIndex: 3,
            totalFiles: 10,
            currentFileProgress: 0.5,
            overallProgress: 0.35,
            currentFileName: "test.jpg",
            state: .running,
            estimatedTimeRemaining: nil
        )
        XCTAssertEqual(viewModel.getStatusText(for: [activeTask]), "Importing 4 of 10")
        
        // Test for multiple active tasks
        var activeTask2 = ImportTask(media: Array(repeating: CleartextMedia(source: .data(Data()), generateID: true), count: 5), albumId: "album2", source: .files)
        activeTask2.progress.state = .running
        XCTAssertEqual(viewModel.getStatusText(for: [activeTask, activeTask2]), "Importing 2 batches")
    }
    
    func testImportTaskWithAssetIdentifiers() {
        // Test creating ImportTask with asset identifiers
        let assetIds = ["asset1", "asset2", "asset3"]
        let media = [
            CleartextMedia(source: .data(Data()), generateID: true),
            CleartextMedia(source: .data(Data()), generateID: true),
            CleartextMedia(source: .data(Data()), generateID: true)
        ]
        
        let task = ImportTask(media: media, albumId: "testAlbum", source: .photos, assetIdentifiers: assetIds)
        
        // Verify the task stores asset identifiers correctly
        XCTAssertEqual(task.assetIdentifiers, assetIds)
        XCTAssertEqual(task.assetIdentifiers.count, 3)
        XCTAssertEqual(task.media.count, 3)
        XCTAssertEqual(task.albumId, "testAlbum")
        
        // Test creating ImportTask without asset identifiers (default empty array)
        let taskWithoutAssets = ImportTask(media: media, albumId: "testAlbum", source: .files)
        XCTAssertEqual(taskWithoutAssets.assetIdentifiers, [])
    }
} 
