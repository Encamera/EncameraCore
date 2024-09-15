//
//  OnboardingViewError.swift
//  Encamera
//
//  Created by Alexander Freas on 15.09.24.
//

import Foundation

enum OnboardingViewError: Error {
    case passwordInvalid
    case onboardingEnded
    case missingStorageType
    case advanceImageCarousel // hax
}
