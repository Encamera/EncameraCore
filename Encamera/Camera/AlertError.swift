//
//  AlertError.swift
//  Encamera
//
//  Created by Alexander Freas on 04.07.22.
//

import Foundation
import EncameraCore

struct AlertError {
    var title: String = ""
    var message: String = ""
    var primaryButtonTitle = L10n.accept
    var secondaryButtonTitle: String?
    var primaryAction: (() -> ())?
    var secondaryAction: (() -> ())?
    
    init(title: String = "", message: String = "", primaryButtonTitle: String = L10n.accept, secondaryButtonTitle: String? = nil, primaryAction: (() -> ())? = nil, secondaryAction: (() -> ())? = nil) {
        self.title = title
        self.message = message
        self.primaryAction = primaryAction
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryAction = secondaryAction
    }
}
