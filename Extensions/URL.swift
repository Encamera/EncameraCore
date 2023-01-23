//
//  URL.swift
//  Encamera
//
//  Created by Alexander Freas on 27.10.22.
//

import Foundation

extension URL {
    public static var tempMediaURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(),
                                    isDirectory: true)
        .appendingPathComponent("current")
        .appendingPathExtension("mov")
    }
}
