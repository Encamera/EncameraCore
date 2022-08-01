//
//  QRCodeCaptureProcessor.swift
//  Encamera
//
//  Created by Alexander Freas on 22.11.21.
//

import Foundation
import AVFoundation
import Combine

class QRCodeCaptureProcessor: NSObject {
    var supportedObjectTypes: [AVMetadataObject.ObjectType] {
        return [.qr]
    }
    
    @Published var lastValidKeyObject: ImageKey?
    
}

extension QRCodeCaptureProcessor: AVCaptureMetadataOutputObjectsDelegate {
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let object = metadataObjects.first {
            guard let readableObject = object as? AVMetadataMachineReadableCodeObject, let stringValue = readableObject.stringValue, let keyObject = try?  ImageKey(base64String: stringValue), lastValidKeyObject != keyObject else {
                return
            }
            lastValidKeyObject = keyObject
            debugPrint(keyObject)
            
        }
    }
    
}
