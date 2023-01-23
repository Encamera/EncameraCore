//
//  ShareViewController.swift
//  ShareExtension
//
//  Created by Alexander Freas on 23.01.23.
//

import UIKit
import MobileCoreServices

@objc(ShareExtensionViewController)
class ShareViewController: UIViewController {

  override func viewDidLoad() {
    super.viewDidLoad()
    
    self.handleSharedFile()
  }
  
    private func handleSharedFile() {
      // extracting the path to the URL that is being shared
      let attachments = (self.extensionContext?.inputItems.first as? NSExtensionItem)?.attachments ?? []
      let contentType = kUTTypeData as String
      for provider in attachments {
        // Check if the content type is the same as we expected
        if provider.hasItemConformingToTypeIdentifier(contentType) {
          provider.loadItem(forTypeIdentifier: contentType,
                            options: nil) { [unowned self] (data, error) in
          // Handle the error here if you want
          guard error == nil else { return }
               
          if let url = data as? URL,
             let imageData = try? Data(contentsOf: url) {
               self.save(imageData, key: "imageData", value: imageData)
          } else {
            // Handle this situation as you prefer
            fatalError("Impossible to save image")
          }
        }}
      }
    }
      
    private func save(_ data: Data, key: String, value: Any) {
        print(data)
      // You must use the userdefaults of an app group, otherwise the main app don't have access to it.
//      let userDefaults = UserDefaults(suiteName: appGroupName)
//      userDefaults.set(data, forKey: key)
    }

}
