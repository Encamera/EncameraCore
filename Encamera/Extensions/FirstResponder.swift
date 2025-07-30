//
//  FirstResponder.swift
//  Encamera
//
//  Created by Alexander Freas on 22.10.24.
//

import SwiftUIIntrospect
import SwiftUI

extension View {

    func becomeFirstResponder() -> some View {
        self.introspect(.textField, on: .iOS(.v13, .v14, .v15, .v16, .v17, .v18)) { (textField: UITextField) in
            // Delay to avoid NavigationStack conflicts in iOS 16.4+
            DispatchQueue.main.async {
                textField.becomeFirstResponder()
            }
        }
    }

    func introspectTextField(_ callback: @escaping (UITextField) -> ()) -> some View {
        self.introspect(.textField, on: .iOS(.v13, .v14, .v15, .v16, .v17, .v18)) { (textField: UITextField) in
            callback(textField)
        }
    }
}
