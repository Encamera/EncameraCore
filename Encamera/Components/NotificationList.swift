//
//  NotificationCarousel.swift
//  Encamera
//
//  Created by Alexander Freas on 20.12.23.
//

import SwiftUI
import EncameraCore

class NotificationListViewModel: ObservableObject {
    @Published var selectedTabIndex: Int = 0
    @Published var notifications: [NotificationBannerViewModel] = []
    @Published var showingWebView = false
    @Published var webViewURL: URL?

    private var notificationRepository: NotificationContentRepository = NotificationContentRepository()

    init() {
        let tappedAction: (URL) -> Void = { [weak self] url in
            self?.webViewURL = url
            self?.showingWebView = true
        }
        self.notifications = notificationRepository.allNotifications(tappedAction: tappedAction).shuffled()
    }
}

struct NotificationList: View {
    @StateObject private var viewModel: NotificationCarouselViewModel = .init()
    @Binding var isPresented: Bool
    private var divider: some View {
        Divider()
            .frame(height: 1)
            .background(Color.notificationDividerColor)
    }

    var body: some View {
        LazyVStack {
            ForEach(Array(viewModel.notifications.enumerated()), id: \.element.id) { index, notif in
                NotificationBanner(viewModel: notif)
                    .tag(index)
            }
        }
        .frame(maxHeight: .infinity)
        .onChange(of: viewModel.selectedTabIndex) { oldValue, newValue in
            let viewedNotification = viewModel.notifications[newValue]
            EventTracking.trackNotificationSwipedViewed(title: viewedNotification.titleText)
        }

        .tabViewStyle(.page(indexDisplayMode: .never))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .if(!isPresented) { view in
            view.opacity(0).frame(height: 0)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.09))
        .transition(.opacity)
        .sheet(isPresented: $viewModel.showingWebView) {
            WebView(url: viewModel.webViewURL)
        }
    }
}


#Preview {
    ZStack {
        Color.black
        NotificationList(isPresented: .constant(true))
    }
}
