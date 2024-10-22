//
//  NotificationBell.swift
//  Encamera
//
//  Created by Alexander Freas on 26.11.23.
//

import SwiftUI

struct NotificationBell: View {

    @State var showIndicator: Bool = false
    var body: some View {
            ZStack(alignment: .topTrailing, content: {

                Image("Bell-Notification")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showIndicator {
                    Ellipse()
                        .stroke(.black, lineWidth: 3)
                        .fill(Color.notificationBadgeColor)
                        .foregroundColor(.notificationBadgeColor)
                        .frame(width: 10, height: 10)
                        .offset(x: 5, y: -5)

                }
            })
        .frame(width: 20, height: 32)
        .frostedButton()
    }
}

#Preview {
    VStack {
        NotificationBell()
        .scaleEffect(5.0)
        Spacer()
        NotificationBell(showIndicator: true)
        .scaleEffect(5.0)
    }.frame(height: 400)
}
