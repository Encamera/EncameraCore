import SwiftUI
import UIKit

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
                            triggerHapticFeedback()
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

    private func triggerHapticFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
}

#Preview {
    DualButtonComponent(nextActive: .constant(false), bottomButtonTitle: "Continue", bottomButtonAction: {
        print("Continue")
    }, secondaryButtonTitle: "Back", secondaryButtonAction: {
        print("Back")
    })
}
