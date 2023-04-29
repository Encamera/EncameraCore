//
//  LockScreenKeypad.swift
//  Encamera
//
//  Created by Alexander Freas on 29.04.23.
//

import Foundation
import SwiftUI

struct LockScreenKeypad: View {
    let buttons: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [" ", "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<buttons.count) { row in
                HStack(spacing: 12) {
                    ForEach(buttons[row], id: \.self) { button in
                        KeypadButton(title: button)
                    }
                }
            }
        }
        .padding()
    }
}

struct KeypadButton: View {
    let title: String

    var body: some View {
        Button(action: {
            // Handle button tap
            print("Tapped: \(title)")
        }) {
            ZStack {
                if !title.isEmpty {
                    RoundedRectangle(cornerRadius: 12)
                        .frame(width: 75, height: 75)
                        .foregroundColor(.gray.opacity(0.2))
                }

                Text(title)
                    .font(.system(size: 36, weight: .semibold))
            }
        }
    }
}

struct LockScreenKeypad_Previews: PreviewProvider {
    static var previews: some View {
        LockScreenKeypad()
    }
}
