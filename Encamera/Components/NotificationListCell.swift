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
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.titleText)
                    .lineLimit(2, reservesSpace: true)
                    .fontType(.pt16, weight: .bold)
                    .foregroundColor(.white)
                Text(viewModel.bodyText)
                    .fontType(.pt14)
                    .lineLimit(3, reservesSpace: true)
                    .opacity(0.80)
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
            .padding([.top], 24)
            if let image = viewModel.image {
                Spacer()
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 100)
            }
        }
        .padding([.leading, .trailing], 24)

        .background(Color(red: 0.09, green: 0.09, blue: 0.09))

    }
}

//#Preview {
//    NotificationListCell(viewModel: .init())
//}
