//
//  NotificationContentRepository.swift
//  Encamera
//
//  Created by Alexander Freas on 15.09.24.
//

import Foundation
import EncameraCore
import SwiftUI

class NotificationContentRepository {


    func allNotifications(tappedAction: @escaping (URL) -> Void) -> [NotificationListCellViewModel] {
        return [
            .init(image: Image("NotificationBanner-LeaveReview"), titleText: L10n.NotificationBanner.LeaveAReview.title, bodyText: L10n.NotificationBanner.LeaveAReview.body, buttonText: L10n.leaveAReview, buttonUrl: AskForReviewUtil.reviewURL, id: 1, tappedAction: { _ in
                Task { @MainActor in
                    AskForReviewUtil.openAppStoreReview()
                }
            }),
            .init(image: Image("NotificationBanner-Reddit"), titleText: L10n.NotificationBanner.Reddit.title, bodyText: L10n.NotificationBanner.Reddit.body, buttonText: L10n.NotificationBanner.Reddit.button, buttonUrl: URL(string: "https://www.reddit.com/r/encamera/")!, id: 2, tappedAction: { url in
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }),
            .init(image: Image("Telegram-Logo"), titleText: L10n.telegramGroupJoinTitle, bodyText: L10n.telegramGroupJoinBody, buttonText: L10n.telegramGroupJoinButtonText, buttonUrl: URL(string: "https://t.me/encamera_app")!, id: 3),
            .init(image: Image("NotificationBanner-Widget"), titleText: L10n.installWidgetTitle, bodyText: L10n.installWidgetBody, buttonText: L10n.installWidgetButtonText, buttonUrl: AppConstants.widgetVimeoLink, id: 4, tappedAction: tappedAction),

        ]
    }


}
