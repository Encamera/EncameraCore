//
//  DateUtils.swift
//  EncameraTests
//
//  Created by Alexander Freas on 23.06.22.
//

import Foundation


class DateUtils {
    
    private static var formatter: DateFormatter = {
       let formatter = DateFormatter()
        formatter.dateFormat = "YYYY.MM.dd"
        return formatter
    }()
    
    static func dateOnlyString(from date: Date) -> String {
        formatter.string(from: date)
    }
}
