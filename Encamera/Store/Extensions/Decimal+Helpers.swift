//
//  Decimal+Helpers.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation

// Helper extension to round Decimal values
extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var roundedValue = Decimal()
        NSDecimalRound(&roundedValue, &value, scale, .plain)
        return roundedValue
    }
}

