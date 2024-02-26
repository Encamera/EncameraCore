//
//  NotificationBanner.swift
//  Encamera
//
//  Created by Alexander Freas on 09.12.23.
//

import SwiftUI

class NotificationBannerViewModel: ObservableObject, Identifiable {
    var image: Image? = Image("NotificationBanner-Lock")
    var titleText: String = "Add Widget"
    var bodyText: String = "Non explicabo officia aut odit ex  eum ipsum libero."
    var buttonText: String?
    var buttonUrl: URL?
    var id: Int = 0

    init(image: Image? = nil, titleText: String, bodyText: String, buttonText: String? = nil, buttonUrl: URL? = nil, id: Int) {
        self.image = image
        self.titleText = titleText
        self.bodyText = bodyText
        self.buttonText = buttonText
        self.buttonUrl = buttonUrl
        self.id = id
    }
}

struct NotificationBanner: View {
    @ObservedObject var viewModel: NotificationBannerViewModel
    var body: some View {
            GeometryReader { geo in

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
                        Spacer()
                        Button(action: {
                            guard let url = viewModel.buttonUrl else { return }
                            Task {
                                await UIApplication.shared.open(url)
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

            }
            .background(Color(red: 0.09, green: 0.09, blue: 0.09))

    }
}

//#Preview {
//    NotificationBanner(viewModel: .init())
//}
