import Foundation
import UIKit
import EncameraCore

public class DemoFileEnumerator: FileAccess {
    public func setKeyUUIDForExistingFiles() async throws {
        
    }
    
    public var directoryModel: DataStorageModel? = DemoDirectoryModel()

    private var mediaList: [InteractableMedia<EncryptedMedia>] = []

    public static var shared = DemoFileEnumerator()

    public required init() {
        Task {
            mediaList = await enumerateMedia()
        }
    }

    public func loadMediaToURLs(media: InteractableMedia<EncryptedMedia>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> [URL] {
        return []
    }

    public required init(for album: Album, albumManager: AlbumManaging) async {
        mediaList = await enumerateMedia()
    }

    public func configure(for album: Album, albumManager: AlbumManaging) async {
        // Implementation here
    }

    public func copy(media: InteractableMedia<EncryptedMedia>) async throws {
        // Implementation here
    }

    public func move(media: InteractableMedia<EncryptedMedia>) async throws {
        // Implementation here
    }

    @discardableResult
    public func createPreview(for media: InteractableMedia<CleartextMedia>) async throws -> PreviewModel {
        return PreviewModel(thumbnailMedia: CleartextMedia(source: .data(Data()), mediaType: .preview, id: "sdf"))
    }

    public func deleteMediaForKey() async throws {
        // Implementation here
    }

    public func deleteAllMedia() async throws {
        // Implementation here
    }

    public static func deleteThumbnailDirectory() throws {
        // Implementation here
    }

    public func loadMedia<T>(media: InteractableMedia<T>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> where T : MediaDescribing {
        let url = URL(fileURLWithPath: "/Users/akfreas/github/Encamera/Encamera/PreviewAssets/1.jpg")
        let data = try! Data(contentsOf: url)
        debugPrint("url", Bundle.main.bundleURL)
        let image = try! InteractableMedia(underlyingMedia: [CleartextMedia(source: .data(data))])
        image.mediaType = .livePhoto
        return image
    }

    public func loadMediaInMemory(media: InteractableMedia<EncryptedMedia>, progress: @escaping (FileLoadingStatus) -> Void) async throws -> InteractableMedia<CleartextMedia> {
        let cleartextMedia = CleartextMedia(source: Data())
        return try InteractableMedia(underlyingMedia: [cleartextMedia])
    }

    public func save(media: InteractableMedia<CleartextMedia>, progress: @escaping (Double) -> Void) async throws -> InteractableMedia<EncryptedMedia>? {
        let encryptedMedia = EncryptedMedia(source: URL(fileURLWithPath: ""), mediaType: .photo, id: "1234")
        return try InteractableMedia(underlyingMedia: [encryptedMedia])
    }

    public func loadMediaPreview<T: MediaDescribing>(for media: InteractableMedia<T>) async throws -> PreviewModel {
        guard let source = media.photoURL,
              let data = try? Data(contentsOf: source) else {
            return try PreviewModel(source: CleartextMedia(source: Data()))
        }
        let cleartext = CleartextMedia(source: data)
        let preview = PreviewModel(thumbnailMedia: cleartext)
        return preview
    }

    public func enumerateMedia<T>() async -> [InteractableMedia<T>] where T : MediaDescribing {
        let retVal: [InteractableMedia<T>] = (7...31).compactMap { val in
            let url = URL(fileURLWithPath: "/Users/akfreas/github/Encamera/Encamera/\(val)")
            return try? InteractableMedia(underlyingMedia: [T(source: .url(url), mediaType: .photo, id: "\(val)")])
        }.shuffled()
        return retVal
    }

    public func delete(media: [InteractableMedia<EncryptedMedia>]) async throws {
        // Implementation here
    }

    public func loadLeadingThumbnail() async throws -> UIImage? {
        guard let last = mediaList.popLast(), case .url(let source) = last.thumbnailSource.source else {
            return nil
        }
        return UIImage(data: try Data(contentsOf: source))
    }
}
