import XCTest
import Photos
import PhotosUI
@testable import Encamera

@MainActor
class CustomPhotoPickerViewModelTests: XCTestCase {
    
    var viewModel: CustomPhotoPickerViewModel!
    var mockAssets: [MockPHAsset]!
    
    override func setUp() async throws {
        try await super.setUp()
        viewModel = CustomPhotoPickerViewModel()
        
        // Create mock assets for testing
        mockAssets = [
            MockPHAsset(localIdentifier: "asset1", mediaType: .image),
            MockPHAsset(localIdentifier: "asset2", mediaType: .image),
            MockPHAsset(localIdentifier: "asset3", mediaType: .video),
            MockPHAsset(localIdentifier: "asset4", mediaType: .image),
            MockPHAsset(localIdentifier: "asset5", mediaType: .video)
        ]
    }
    
    override func tearDown() async throws {
        viewModel = nil
        mockAssets = nil
        try await super.tearDown()
    }
    
    // MARK: - Selection Management Tests
    
    func testSelectAsset() {
        let asset = mockAssets[0]
        
        let result = viewModel.selectAsset(asset)
        
        XCTAssertTrue(result)
        XCTAssertTrue(viewModel.selectedAssets.contains(asset))
        XCTAssertEqual(viewModel.selectionCount, 1)
        XCTAssertTrue(viewModel.hasSelectedAssets)
    }
    
    func testSelectSameAssetTwice() {
        let asset = mockAssets[0]
        
        let firstResult = viewModel.selectAsset(asset)
        let secondResult = viewModel.selectAsset(asset)
        
        XCTAssertTrue(firstResult)
        XCTAssertFalse(secondResult) // Should not select same asset twice
        XCTAssertEqual(viewModel.selectionCount, 1)
    }
    
    func testDeselectAsset() {
        let asset = mockAssets[0]
        
        // First select the asset
        viewModel.selectAsset(asset)
        XCTAssertTrue(viewModel.selectedAssets.contains(asset))
        
        // Then deselect it
        let result = viewModel.deselectAsset(asset)
        
        XCTAssertTrue(result)
        XCTAssertFalse(viewModel.selectedAssets.contains(asset))
        XCTAssertEqual(viewModel.selectionCount, 0)
        XCTAssertFalse(viewModel.hasSelectedAssets)
    }
    
    func testDeselectNonSelectedAsset() {
        let asset = mockAssets[0]
        
        let result = viewModel.deselectAsset(asset)
        
        XCTAssertFalse(result) // Should return false when trying to deselect non-selected asset
        XCTAssertEqual(viewModel.selectionCount, 0)
    }
    
    func testToggleAssetSelection() {
        let asset = mockAssets[0]
        
        // Toggle to select
        let firstToggle = viewModel.toggleAssetSelection(asset)
        XCTAssertTrue(firstToggle)
        XCTAssertTrue(viewModel.selectedAssets.contains(asset))
        
        // Toggle to deselect
        let secondToggle = viewModel.toggleAssetSelection(asset)
        XCTAssertTrue(secondToggle)
        XCTAssertFalse(viewModel.selectedAssets.contains(asset))
    }
    
    func testIsAssetSelected() {
        let asset = mockAssets[0]
        
        XCTAssertFalse(viewModel.isAssetSelected(asset))
        
        viewModel.selectAsset(asset)
        XCTAssertTrue(viewModel.isAssetSelected(asset))
        
        viewModel.deselectAsset(asset)
        XCTAssertFalse(viewModel.isAssetSelected(asset))
    }
    
    func testGetSelectionNumber() {
        let asset1 = mockAssets[0]
        let asset2 = mockAssets[1]
        let asset3 = mockAssets[2]
        
        viewModel.selectAsset(asset1)
        viewModel.selectAsset(asset2)
        viewModel.selectAsset(asset3)
        
        XCTAssertEqual(viewModel.getSelectionNumber(for: asset1), 1)
        XCTAssertEqual(viewModel.getSelectionNumber(for: asset2), 2)
        XCTAssertEqual(viewModel.getSelectionNumber(for: asset3), 3)
        XCTAssertNil(viewModel.getSelectionNumber(for: mockAssets[3]))
    }
    
    func testClearSelection() {
        // Select multiple assets
        viewModel.selectAsset(mockAssets[0])
        viewModel.selectAsset(mockAssets[1])
        viewModel.selectAsset(mockAssets[2])
        
        XCTAssertEqual(viewModel.selectionCount, 3)
        
        viewModel.clearSelection()
        
        XCTAssertEqual(viewModel.selectionCount, 0)
        XCTAssertFalse(viewModel.hasSelectedAssets)
        XCTAssertTrue(viewModel.selectedAssets.isEmpty)
    }
    
    // MARK: - Selection Limits Tests
    
    func testSelectionLimit() {
        viewModel.selectionLimit = 2
        
        let asset1 = mockAssets[0]
        let asset2 = mockAssets[1]
        let asset3 = mockAssets[2]
        
        // Should be able to select up to limit
        XCTAssertTrue(viewModel.canSelectAsset(asset1))
        XCTAssertTrue(viewModel.selectAsset(asset1))
        
        XCTAssertTrue(viewModel.canSelectAsset(asset2))
        XCTAssertTrue(viewModel.selectAsset(asset2))
        
        // Should not be able to select beyond limit
        XCTAssertFalse(viewModel.canSelectAsset(asset3))
        XCTAssertFalse(viewModel.selectAsset(asset3))
        
        XCTAssertEqual(viewModel.selectionCount, 2)
        XCTAssertTrue(viewModel.isAtSelectionLimit)
        XCTAssertEqual(viewModel.remainingSelectionCount, 0)
    }
    
    func testSelectionLimitUnlimited() {
        viewModel.selectionLimit = 0 // Unlimited
        
        // Should be able to select all assets
        for asset in mockAssets {
            XCTAssertTrue(viewModel.canSelectAsset(asset))
            XCTAssertTrue(viewModel.selectAsset(asset))
        }
        
        XCTAssertEqual(viewModel.selectionCount, mockAssets.count)
        XCTAssertFalse(viewModel.isAtSelectionLimit)
        XCTAssertEqual(viewModel.remainingSelectionCount, Int.max)
    }
    
    func testCanSelectAssetWhenAlreadySelected() {
        viewModel.selectionLimit = 1
        let asset = mockAssets[0]
        
        viewModel.selectAsset(asset)
        
        // Should still be able to "select" an already selected asset (for UI purposes)
        XCTAssertTrue(viewModel.canSelectAsset(asset))
    }
    
    func testUpdateSelectionLimitTrimsSelection() {
        // Select 3 assets
        viewModel.selectAsset(mockAssets[0])
        viewModel.selectAsset(mockAssets[1])
        viewModel.selectAsset(mockAssets[2])
        
        XCTAssertEqual(viewModel.selectionCount, 3)
        
        // Set limit to 2, should trim to first 2 selected
        viewModel.updateSelectionLimit(2)
        
        XCTAssertEqual(viewModel.selectionCount, 2)
        XCTAssertEqual(viewModel.selectionLimit, 2)
        XCTAssertTrue(viewModel.selectedAssets.contains(mockAssets[0]))
        XCTAssertTrue(viewModel.selectedAssets.contains(mockAssets[1]))
        XCTAssertFalse(viewModel.selectedAssets.contains(mockAssets[2]))
    }
    
    // MARK: - Selection Mode Tests
    
    func testSelectionModeManagement() {
        XCTAssertFalse(viewModel.isInSelectionMode)
        
        viewModel.enterSelectionMode()
        XCTAssertTrue(viewModel.isInSelectionMode)
        
        viewModel.exitSelectionMode()
        XCTAssertFalse(viewModel.isInSelectionMode)
    }
    
    // MARK: - Batch Operations Tests
    
    func testSelectAssetsBatch() {
        let assetsToSelect = Array(mockAssets[0...2])
        
        let successfullySelected = viewModel.selectAssets(assetsToSelect)
        
        XCTAssertEqual(successfullySelected.count, 3)
        XCTAssertEqual(viewModel.selectionCount, 3)
        
        for asset in assetsToSelect {
            XCTAssertTrue(viewModel.selectedAssets.contains(asset))
        }
    }
    
    func testSelectAssetsBatchWithLimit() {
        viewModel.selectionLimit = 2
        let assetsToSelect = Array(mockAssets[0...2])
        
        let successfullySelected = viewModel.selectAssets(assetsToSelect)
        
        XCTAssertEqual(successfullySelected.count, 2)
        XCTAssertEqual(viewModel.selectionCount, 2)
    }
    
    func testDeselectAssetsBatch() {
        // First select some assets
        let assetsToSelect = Array(mockAssets[0...2])
        viewModel.selectAssets(assetsToSelect)
        
        // Then deselect some of them
        let assetsToDeselect = Array(mockAssets[1...2])
        let successfullyDeselected = viewModel.deselectAssets(assetsToDeselect)
        
        XCTAssertEqual(successfullyDeselected.count, 2)
        XCTAssertEqual(viewModel.selectionCount, 1)
        XCTAssertTrue(viewModel.selectedAssets.contains(mockAssets[0]))
        XCTAssertFalse(viewModel.selectedAssets.contains(mockAssets[1]))
        XCTAssertFalse(viewModel.selectedAssets.contains(mockAssets[2]))
    }
    
    // MARK: - OrderedSet Tests
    
    func testOrderedSetMaintainsOrder() {
        let asset1 = mockAssets[0]
        let asset2 = mockAssets[1]
        let asset3 = mockAssets[2]
        
        viewModel.selectAsset(asset1)
        viewModel.selectAsset(asset2)
        viewModel.selectAsset(asset3)
        
        let selectedArray = viewModel.selectedAssets.array
        XCTAssertEqual(selectedArray[0], asset1)
        XCTAssertEqual(selectedArray[1], asset2)
        XCTAssertEqual(selectedArray[2], asset3)
    }
    
    func testOrderedSetNoDuplicates() {
        var orderedSet = OrderedSet<String>()
        
        orderedSet.append("first")
        orderedSet.append("second")
        orderedSet.append("first") // Duplicate
        
        XCTAssertEqual(orderedSet.count, 2)
        XCTAssertEqual(orderedSet.array, ["first", "second"])
    }
    
    func testOrderedSetRemoval() {
        var orderedSet = OrderedSet<String>()
        
        orderedSet.append("first")
        orderedSet.append("second")
        orderedSet.append("third")
        
        orderedSet.remove("second")
        
        XCTAssertEqual(orderedSet.count, 2)
        XCTAssertEqual(orderedSet.array, ["first", "third"])
        XCTAssertFalse(orderedSet.contains("second"))
    }
    
    // MARK: - Validation Tests
    
    func testHasSelectedAssets() {
        XCTAssertFalse(viewModel.hasSelectedAssets)
        
        viewModel.selectAsset(mockAssets[0])
        XCTAssertTrue(viewModel.hasSelectedAssets)
        
        viewModel.clearSelection()
        XCTAssertFalse(viewModel.hasSelectedAssets)
    }
    
    func testIsAtSelectionLimit() {
        viewModel.selectionLimit = 2
        
        XCTAssertFalse(viewModel.isAtSelectionLimit)
        
        viewModel.selectAsset(mockAssets[0])
        XCTAssertFalse(viewModel.isAtSelectionLimit)
        
        viewModel.selectAsset(mockAssets[1])
        XCTAssertTrue(viewModel.isAtSelectionLimit)
    }
    
    func testRemainingSelectionCount() {
        viewModel.selectionLimit = 3
        
        XCTAssertEqual(viewModel.remainingSelectionCount, 3)
        
        viewModel.selectAsset(mockAssets[0])
        XCTAssertEqual(viewModel.remainingSelectionCount, 2)
        
        viewModel.selectAsset(mockAssets[1])
        XCTAssertEqual(viewModel.remainingSelectionCount, 1)
        
        viewModel.selectAsset(mockAssets[2])
        XCTAssertEqual(viewModel.remainingSelectionCount, 0)
    }
}

// MARK: - Mock PHAsset for Testing
class MockPHAsset: PHAsset {
    private let _localIdentifier: String
    private let _mediaType: PHAssetMediaType
    
    init(localIdentifier: String, mediaType: PHAssetMediaType) {
        self._localIdentifier = localIdentifier
        self._mediaType = mediaType
        super.init()
    }
    
    override var localIdentifier: String {
        return _localIdentifier
    }
    
    override var mediaType: PHAssetMediaType {
        return _mediaType
    }
    
    // Implement Hashable for use in OrderedSet
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MockPHAsset else { return false }
        return localIdentifier == other.localIdentifier
    }
    
    override var hash: Int {
        return localIdentifier.hashValue
    }
} 