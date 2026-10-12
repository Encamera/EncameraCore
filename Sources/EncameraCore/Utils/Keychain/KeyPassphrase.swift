//
//  KeyPassphrase.swift
//  Encamera
//

import Foundation

public struct KeyPassphrase: Codable {
    public let words: [String]

    public init(words: [String]) {
        self.words = words
    }
}
