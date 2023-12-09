//
//  NotificationBell.swift
//  Encamera
//
//  Created by Alexander Freas on 26.11.23.
//

import SwiftUI

struct NotificationBell: View {

    @State var showIndicator: Bool = false
    var action: () -> ()
    var body: some View {
        Button(action: action) {
            ZStack() {
                ZStack(alignment: .topTrailing, content: {

                    Ellipse()
                        .foregroundColor(.clear)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Ellipse()
                                .inset(by: 0.50)
                                .stroke(
                                    .white.opacity(0.3), lineWidth: 1
                                )
                        )
                        .offset(x: 0, y: 0)
                    Image("Bell-Notification")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showIndicator {
                        Ellipse()
                            .foregroundColor(.notificationBadgeColor)
                            .frame(width: 10, height: 10)
                    }
                })
            }
            .frame(width: 32, height: 32)
        }
    }
}

#Preview {
    VStack {
        NotificationBell() {

        }
            .scaleEffect(5.0)
        Spacer()
        NotificationBell(showIndicator: true) {

        }
            .scaleEffect(5.0)
    }.frame(height: 400)
}
