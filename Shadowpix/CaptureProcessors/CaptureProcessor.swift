//
//  CaptureProcessor.swift
//  Shadowpix
//
//  Created by Alexander Freas on 02.06.22.
//

import Foundation
import AVFoundation

protocol CaptureProcessor {
    init(
        willCapturePhotoAnimation: @escaping () -> Void,
        completionHandler: @escaping (CaptureProcessor) -> Void,
        photoProcessingHandler: @escaping (Bool) -> Void,
        fileWriter: FileWriter)
}
