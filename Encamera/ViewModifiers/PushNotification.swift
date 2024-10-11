//
//  PushNotification.swift
//  Encamera
//
//  Created by Alexander Freas on 11.10.24.
//
import SwiftUI

extension View {

    @ViewBuilder
    func pushNotificationPromptModal(isPresented: Binding<Bool>, onPrimaryButtonPressed: @escaping () -> Void, onSecondaryButtonPressed: @escaping () -> Void) -> some View {
        self.genericModal(isPresented: isPresented, imageName: "NotificationBell", titleText: "Be the first to know", descriptionText: "Enable notifications to get feature updates, exclusive promotions, and security reminders", primaryButtonText: "Enable", secondaryButtonText: "Later", onPrimaryButtonPressed: onPrimaryButtonPressed, onSecondaryButtonPressed: onSecondaryButtonPressed, animated: true, addOverlay: true)
    }
}

#Preview {
    Text("Hello, World!")
        .pushNotificationPromptModal(isPresented: .constant(true), onPrimaryButtonPressed: {}, onSecondaryButtonPressed: {})

}
