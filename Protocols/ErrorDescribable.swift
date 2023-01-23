//
//  ErrorDescribable.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import Foundation

protocol ErrorDescribable: Error {
    var displayDescription: String { get }
}
