//
//  AppConstants.swift
//  encamera
//
//  Created by Alexander Freas on 11.11.21.
//

import Foundation

enum AppConstants {
    
    static var authenticationTimeout: RunLoop.SchedulerTimeType.Stride = 20
    static var deeplinkSchema = "encamera"
    static var thumbnailWidth: CGFloat = 70
    static var blockingBlurRadius: CGFloat = 10.0
    static var numberOfPhotosBeforeInitialTutorial: Double = 1
    static let maxPhotoCountBeforePurchase: Double = 5

}
