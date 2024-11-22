//
//  Array+Safe.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.24.
//

import Foundation
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
