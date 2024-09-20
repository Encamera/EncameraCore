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
    @Published var notifications: [NotificationListCellViewModel] = []
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

    @StateObject private var viewModel: NotificationListViewModel = .init()
    var closeAction: () -> (Void)
    private var divider: some View {
        Divider()
            .frame(height: 1)
            .background(Color.notificationDividerColor)
    }

    var body: some View {
        VStack {
            HStack {

                Text(L10n.notificationListTitle)
                    .fontType(.pt20, weight: .bold)
                Spacer()
                Button {
                    closeAction()
                } label: {
                    Image("Close-X")
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20) // Adjust size as needed
                        .foregroundStyle(.white)
                }
                .frostedButton()
            }
            .padding([.leading, .trailing], Spacing.pt24.value)
            .padding([.top, .bottom], Spacing.pt16.value)
            ScrollView {
                LazyVStack(spacing: Spacing.pt8.value) {
                    ForEach(Array(viewModel.notifications.enumerated()), id: \.element.id) { index, notif in
                        NotificationListCell(viewModel: notif)
                            .tag(index)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: viewModel.selectedTabIndex) { oldValue, newValue in
                let viewedNotification = viewModel.notifications[newValue]
                EventTracking.trackNotificationSwipedViewed(title: viewedNotification.titleText)
            }

            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .never))

            .transition(.opacity)
            .sheet(isPresented: $viewModel.showingWebView) {
                WebView(url: viewModel.webViewURL)
            }
            .navigationTitle(L10n.notificationListTitle)
        }
        .gradientBackground()

    }
}


#Preview {
    ZStack {
        Color.black
        NotificationList() {
            
        }
    }
}
