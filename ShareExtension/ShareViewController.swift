//
//  ShareViewController.swift
//  ShareExtension
//
//  Created by Alexander Freas on 23.01.23.
//

import UIKit
import MobileCoreServices
import EncameraCore
import Combine
import UniformTypeIdentifiers

@objc(ShareExtensionViewController)
class ShareViewController: UIViewController {
        
    @IBOutlet weak var firstImage: UIImageView!
    @IBOutlet weak var summaryLabel: UILabel!
    @IBOutlet weak var importButton: UIButton!
    @IBOutlet weak var progressView: UIProgressView!
    
    private var fileAccess: AppGroupFileReader = AppGroupFileReader()
    private var attachments: [NSItemProvider] {
        (self.extensionContext?.inputItems.first as? NSExtensionItem)?.attachments ?? []
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        guard let provider = attachments.first else {
            return
        }
        Task {
            // Check if the content type is the same as we expected
            let matchingMovieTypes = MediaType.supportedMovieFileTypes.filter({provider.hasItemConformingToTypeIdentifier($0.identifier)})
            let matchingPhotoTypes = MediaType.supportedPhotoFileTypes.filter({provider.hasItemConformingToTypeIdentifier($0.identifier)})
            if  matchingPhotoTypes.first != nil {
                try await processImage(provider: provider)
            } else if let matching = matchingMovieTypes.first {
                if matching == UTType.mpeg4Movie {
                    try await processMpeg4Movie(provider: provider)
                } else {
                    try await processQuicktimeMovie(provider: provider)
                }
            } else {
                showUnknownLabel()
            }
            updateLabels(attachments: attachments)
        }
    }
    
    func updateLabels(attachments: [NSItemProvider]) {
        var imageCount = 0
        var videoCount = 0
        
        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                imageCount += 1
            }
            else if attachment.hasItemConformingToTypeIdentifier(UTType.quickTimeMovie.identifier) {
                videoCount += 1
            }
        }
        
        var text = ""
        if imageCount > 0 {
            text += L10n.imageS(imageCount)
        }
        if imageCount > 0 && videoCount > 0 {
            text += ", "
        }
        if videoCount > 0 {
            text += L10n.videoS(videoCount)
        }
        self.summaryLabel.text = text
    }
    
    func showUnknownLabel() {
        importButton.isHidden = true
        summaryLabel.isHidden = false
        summaryLabel.text = L10n.cannotHandleMedia
    }
    
    func processImage(provider: NSItemProvider) async throws {
        let contentType = UTType.image
        let item = try await provider.loadItem(forTypeIdentifier: contentType.identifier)
        var image: UIImage?
        if let url = item as? URL {
            let imageData = try Data(contentsOf: url)
            image = UIImage(data: imageData)
        } else if let data = item as? Data {
            let imageData = data
            image = UIImage(data: imageData)
        } else if let uiImage = item as? UIImage {
            image = uiImage
        }
        
        guard let image = image else {
            debugPrint("Cannot import item", item)
            return
        }
        DispatchQueue.main.async {
            self.firstImage.image = image
        }
    }
    
    
    func processMpeg4Movie(provider: NSItemProvider) async throws {
        let contentType = UTType.mpeg4Movie
        if let url = try await provider.loadItem(forTypeIdentifier: contentType.identifier) as? URL {
            let thumbnail = try await ThumbnailUtils.createThumbnailImageFrom(cleartext: CleartextMedia(source: url))
            DispatchQueue.main.async {
                self.firstImage.image = thumbnail
            }
        } else {
            fatalError("Impossible to save movie")
        }
    }
    
    func processQuicktimeMovie(provider: NSItemProvider) async throws {
        let contentType = UTType.quickTimeMovie
        if let url = try await provider.loadItem(forTypeIdentifier: contentType.identifier) as? URL {
            let thumbnail = try await ThumbnailUtils.createThumbnailImageFrom(cleartext: CleartextMedia(source: url))
            DispatchQueue.main.async {
                self.firstImage.image = thumbnail
            }
        } else {
            fatalError("Impossible to save movie")
        }
    }
    
    func handleImportAction() async {
        importButton.isHidden = true
        var progress = 0
        for attachment in attachments {
            progress += 1
            do {
                let item = try await attachment.loadItem(forTypeIdentifier: attachment.registeredTypeIdentifiers.first ?? "")
                if let url = item as? URL {
                    let media = CleartextMedia(source: url)
                    try await fileAccess.save(media: media) { _ in }
                } else if let uiImage = item as? UIImage, let data = uiImage.jpegData(compressionQuality: 1.0) {
                    let media = CleartextMedia(source: data)
                    try await fileAccess.save(media: media) { _ in }
                } else {
                    print("Unable to save the shared file")
                }
            } catch {
                print("Error loading attachment: \(error)")
            }
        }
        firstImage.isHidden = true
        progressView.isHidden = true
        importFinishedLabel.isHidden = false
        
    }

    @IBOutlet weak var importFinishedLabel: UILabel!
    @IBAction func importButtonPressed(_ sender: Any) {
        Task {
            await handleImportAction()

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.extensionContext!.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }

}
