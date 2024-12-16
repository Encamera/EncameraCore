//
//  FilePicker.swift
//  Encamera
//
//  Created by Alexander Freas on 16.12.24.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FilePicker: UIViewControllerRepresentable {
    private var onFilesPicked: ([URL]) -> Void
    var allowedContentTypes: [UTType] = [.image, .video, .movie] // Customize allowed content types as needed

    init(onFilesPicked: @escaping ([URL]) -> Void) {
        self.onFilesPicked = onFilesPicked
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let isRunningOnIPadMac = ProcessInfo.processInfo.isiOSAppOnMac && UIDevice.current.userInterfaceIdiom == .pad
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: !isRunningOnIPadMac)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true // Set to false if single file selection is preferred
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        // Update the picker view if needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FilePicker

        init(_ parent: FilePicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onFilesPicked(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onFilesPicked([]) // Return an empty array if the user cancels the picker
        }
    }
}
