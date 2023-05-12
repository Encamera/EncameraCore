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
        
    @IBOutlet weak var summaryLabel: UILabel!
    @IBOutlet weak var importSummaryStackView: UIStackView!
    @IBOutlet weak var videoSummaryContainer: UIView!
    @IBOutlet weak var imagesSummaryContainer: UIView!
    @IBOutlet weak var finishImportInstructionsLabel: UILabel!
    @IBOutlet weak var imagesSummaryLabel: UILabel!
    
    @IBOutlet weak var videoSummaryLabel: UILabel!
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
        
        videoSummaryContainer.isHidden = videoCount == 0
        videoSummaryLabel.text = "\(videoCount) \(L10n.videoS(videoCount))"
        
        imagesSummaryContainer.isHidden = imageCount == 0
        imagesSummaryLabel.text = "\(imageCount) \(L10n.imageS(imageCount))"
        
    }
    
    func showUnknownLabel() {
        summaryLabel.isHidden = false
        summaryLabel.text = L10n.cannotHandleMedia
    }
    
    
    func handleImportAction() async {
        importSummaryStackView.isHidden = true
        var progress = 0
        for attachment in attachments {
            progress += 1
            do {
                let item = try await attachment.loadItem(forTypeIdentifier: attachment.registeredTypeIdentifiers.first ?? "")
                if let url = item as? URL {
                    var media = CleartextMedia(source: url)
                    media.id = NSUUID().uuidString
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
        finishImportInstructionsLabel.isHidden = false
        
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
