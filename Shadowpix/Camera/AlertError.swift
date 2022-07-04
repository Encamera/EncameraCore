//
//  AlertError.swift
//  Shadowpix
//
//  Created by Alexander Freas on 04.07.22.
//

import Foundation

struct AlertError {
    var title: String = ""
    var message: String = ""
    var primaryButtonTitle = "Accept"
    var secondaryButtonTitle: String?
    var primaryAction: (() -> ())?
    var secondaryAction: (() -> ())?
    
    init(title: String = "", message: String = "", primaryButtonTitle: String = "Accept", secondaryButtonTitle: String? = nil, primaryAction: (() -> ())? = nil, secondaryAction: (() -> ())? = nil) {
        self.title = title
        self.message = message
        self.primaryAction = primaryAction
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryAction = secondaryAction
    }
}
