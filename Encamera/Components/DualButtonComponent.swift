//
//  DualButtonComponent.swift
//  Encamera
//
//  Created by Alexander Freas on 23.04.24.
//

import SwiftUI

struct DualButtonComponent: View {
    @Binding var nextActive: Bool
    var bottomButtonTitle: String?
    var bottomButtonAction: (() async throws -> Void)?
    var secondaryButtonTitle: String?
    var secondaryButtonAction: (() async throws -> Void)?

    var body: some View {
        VStack {
            if let bottomButtonTitle = bottomButtonTitle {
                Button(bottomButtonTitle) {
                    Task {
                        do {
                            try await bottomButtonAction?()
                            nextActive = true
                        } catch {
                            print("Error on bottom button action", error)
                        }
                    }
                }
                .primaryButton()
            }
            if let secondaryButtonTitle = secondaryButtonTitle {
                Button(secondaryButtonTitle) {
                    Task {
                        do {
                            try await secondaryButtonAction?()
                            nextActive = true
                        } catch {
                            print("Error on secondary button action", error)
                        }
                    }
                }
                .textButton()

            }
        }.padding(14)
    }
}

#Preview {
    DualButtonComponent(nextActive: .constant(false), bottomButtonTitle: "Continue", bottomButtonAction: {
        print("Continue")
    }, secondaryButtonTitle: "Back", secondaryButtonAction: {
        print("Back")
    })
}
