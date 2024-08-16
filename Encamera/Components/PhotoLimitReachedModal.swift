import SwiftUI
import EncameraCore

extension View {
    func photoLimitReachedModal(isPresented: Binding<Bool>, addOverlay: Bool = true, onPrimaryButtonPressed: @escaping () -> Void, onSecondaryButtonPressed: @escaping () -> Void) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .genericModal(
            isPresented: isPresented,
            imageName: "Warning-Triangle",
            titleText: L10n.photoLimitReached,
            descriptionText: L10n.modalUpgradeText,
            primaryButtonText: L10n.upgradeToPremium,
            secondaryButtonText: L10n.cancel,
            onPrimaryButtonPressed: onPrimaryButtonPressed,
            onSecondaryButtonPressed: onSecondaryButtonPressed,
            addOverlay: addOverlay
        )
    }
}

// Usage in a View
struct PhotoLimitReachedModalView: View {
    var body: some View {
        Color.orange
            .photoLimitReachedModal(
                isPresented: .constant(true),
                onPrimaryButtonPressed: { print("Upgrade to Premium") },
                onSecondaryButtonPressed: { print("Back to album") }
            )
    }
}

// Preview
struct PhotoLimitReachedModalView_Previews: PreviewProvider {
    static var previews: some View {
        PhotoLimitReachedModalView()
    }
}
