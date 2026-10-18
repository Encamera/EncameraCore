//
//  ShareMediaUtil.swift
//  EncameraCore
//
//  Created by Alexander Freas on 23.10.24.
//

import Foundation
import UIKit
import LinkPresentation
import UniformTypeIdentifiers

public enum SharingError: Error {
    case noMediaToShare
    case errorDownloading
    case errorSharing(internalError: Error)
}

public class ShareMediaUtil: NSObject, UIActivityItemSource, DebugPrintable {

    let targetMedia: [InteractableMedia<EncryptedMedia>]
    let fileAccess: FileAccess
    var currentSharingPreview: PreviewModel?
    var preparedMediaURLs: [URL] = []

    public init(fileAccess: FileAccess, targetMedia: [InteractableMedia<EncryptedMedia>]) {
        self.targetMedia = targetMedia
        self.fileAccess = fileAccess
        super.init()
    }
    
    /// Configures popover presentation for iPad
    /// - Parameters:
    ///   - activityController: The activity view controller to configure
    ///   - sourceView: The view to use as the anchor for the popover
    public static func configurePopoverForIPad(
        activityController: UIActivityViewController,
        sourceView: UIView
    ) {
        if let popoverController = activityController.popoverPresentationController {
            popoverController.sourceView = sourceView
            popoverController.sourceRect = CGRect(
                x: sourceView.bounds.midX,
                y: sourceView.bounds.midY,
                width: 0,
                height: 0
            )
            popoverController.permittedArrowDirections = []
        }
    }

    public func prepareSharingData(progress: @escaping (FileLoadingStatus) -> Void) async throws {

        guard let firstMedia = targetMedia.first else {
            return
        }
        currentSharingPreview = try await fileAccess.loadMediaPreview(for: firstMedia)

        let totalMediaToLoad = targetMedia
            .map({$0.underlyingMedia.count})
            .reduce(0, +)

        guard totalMediaToLoad > 0 else {
            progress(.loaded)
            return
        }

        var overallProgress: Double = 0.0
        let progressLock = NSLock()

        for target in targetMedia {
            do {
                let media = try await self.fileAccess.loadMediaToURLs(media: target) { status in
                    self.printDebug("Status: \(status), overallstatus: \(overallProgress), totalMedia: \(totalMediaToLoad)")
                    progressLock.lock()
                    defer { progressLock.unlock() }

                    switch status {
                    case .downloading(let percent):
                        overallProgress += (percent / Double(totalMediaToLoad))
                    case .decrypting(let percent):
                        overallProgress += (percent / Double(totalMediaToLoad))
                    case .loaded:
                        break
                    case .notLoaded:
                        break
                    }

                    overallProgress = min(max(overallProgress, 0.0), 1.0)

                    progress(.downloading(progress: overallProgress))
                }
                let slowMotion = try? await fileAccess.loadMetadata(for: target)?.video?.slowMotion
                for url in media {
                    preparedMediaURLs.append(await Self.shareableURL(for: url, slowMotion: slowMotion))
                }
            } catch {
                print("Error loading media: \(error)")
            }
        }

        progress(.loaded)
    }

    /// A slow-motion video is shared slowed, under its own filename. A video
    /// without a ramp, or one that fails to render, is shared as it is.
    static func shareableURL(for decrypted: URL, slowMotion: SlowMotionRamp?) async -> URL {
        guard let slowMotion else { return decrypted }
        let directory = decrypted.deletingLastPathComponent()
            .appendingPathComponent("slow-motion-\(UUID().uuidString)", isDirectory: true)
        let destination = directory
            .appendingPathComponent(decrypted.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("mov")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await SlowMotionComposer.render(decrypted, ramp: slowMotion, to: destination)
            return destination
        } catch {
            debugPrint("Sharing slow-motion video at normal speed, render failed: \(error)")
            return decrypted
        }
    }

    @MainActor
    public func showShareSheet() async throws {
        guard !preparedMediaURLs.isEmpty else {
            printDebug("No media loaded")
            return
        }

        let activityView = UIActivityViewController(activityItems: self.preparedMediaURLs + [self], applicationActivities: nil)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activityView.completionWithItemsHandler = { activityType, completed, returnedItems, error in
                if let error = error {
                    self.printDebug("Share error: \(error.localizedDescription)")
                    continuation.resume(throwing: SharingError.errorSharing(internalError: error))
                } else {
                    continuation.resume()
                }
            }

            let allScenes = UIApplication.shared.connectedScenes
            let scene = allScenes.first { $0.activationState == .foregroundActive }

            if let windowScene = scene as? UIWindowScene, let rootViewController = windowScene.keyWindow?.rootViewController {
                var currentVC = rootViewController
                while let presentedVC = currentVC.presentedViewController {
                    currentVC = presentedVC
                }
                
                ShareMediaUtil.configurePopoverForIPad(
                    activityController: activityView,
                    sourceView: currentVC.view
                )
                
                currentVC.present(activityView, animated: true, completion: nil)
            }
        }
    }


    public func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return "Encamera Media"
    }

    public func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return preparedMediaURLs
    }


    public func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()

        if let firstMedia = targetMedia.first, let thumbnailData = currentSharingPreview?.thumbnailMedia.data {
            let imageProvider = NSItemProvider(item: thumbnailData as NSData, typeIdentifier: UTType.png.identifier)
            metadata.imageProvider = imageProvider
            metadata.title = targetMedia.count > 1 ? "Multiple Media Items" : "Media Item"
        } else {
            return nil
        }

        return metadata
    }





}

