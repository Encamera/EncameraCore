//
//  NotificationListCell.swift
//  Encamera
//
//  Created by Alexander Freas on 09.12.23.
//

import SwiftUI
import EncameraCore

class NotificationListCellViewModel: ObservableObject, Identifiable {
    var image: Image? = Image("NotificationListCell-Lock")
    var titleText: String = "Add Widget"
    var bodyText: String = "Non explicabo officia aut odit ex  eum ipsum libero."
    var buttonText: String?
    var buttonUrl: URL?
    var id: Int = 0
    var tappedAction: ((URL) -> Void)?

    init(image: Image? = nil, titleText: String, bodyText: String, buttonText: String? = nil, buttonUrl: URL? = nil, id: Int, tappedAction: ((URL) -> Void)? = nil) {
        self.image = image
        self.titleText = titleText
        self.bodyText = bodyText
        self.buttonText = buttonText
        self.buttonUrl = buttonUrl
        self.id = id
        self.tappedAction = tappedAction
    }

}

struct NotificationListCell: View {
    @ObservedObject var viewModel: NotificationListCellViewModel
    var body: some View {

        HStack {
            VStack(alignment: .leading, spacing: Spacing.pt8.value) {
                HStack(spacing: Spacing.pt16.value) {
                    if let image = viewModel.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                    }
                    Text(viewModel.titleText)
                        .lineLimit(2, reservesSpace: false)
                        .fontType(.pt16, weight: .bold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                }

                Text(viewModel.bodyText)
                    .fontType(.pt14)
                    .lineLimit(3, reservesSpace: true)
                    .opacity(0.80)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: {
                    guard let url = viewModel.buttonUrl else { return }
                    Task {
                        if let tappedAction = viewModel.tappedAction {
                            tappedAction(url)
                        } else {
                            await UIApplication.shared.open(url)
                        }
                    }
                    EventTracking.trackNotificationButtonTapped(url: url)
                }, label: {
                    Text(viewModel.buttonText ?? "")
                        .fontType(.pt14, on: .textButton, weight: .bold)
                })

            }
            .padding([.top, .bottom], 16)
        }
        .padding([.leading, .trailing], 24)
        .frame(height: 190)
        .background(Color(red: 0.09, green: 0.09, blue: 0.09))
        .overlay(
            VStack {
                Group {
                    Rectangle()
                        .frame(height: 1) // Top border
                    Spacer()
                    Rectangle()
                        .frame(height: 1) // Bottom border
                }
                .foregroundColor(.notificationDividerColor)

            }
        )
    }
}

#Preview {
    NotificationListCell(viewModel:.init(image: Image("Telegram-Logo"), titleText: L10n.telegramGroupJoinTitle, bodyText: L10n.telegramGroupJoinBody, buttonText: L10n.telegramGroupJoinButtonText, buttonUrl: URL(string: "https://t.me/encamera_app")!, id: 3))
}
