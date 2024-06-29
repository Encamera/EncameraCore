//
//  NotificationCarousel.swift
//  Encamera
//
//  Created by Alexander Freas on 20.12.23.
//

import SwiftUI
import EncameraCore

struct CustomPageControl: UIViewRepresentable {

    let numberOfPages: Int
    @Binding var currentPage: Int

    func makeUIView(context: Context) -> UIPageControl {
        let view = UIPageControl()
        view.numberOfPages = numberOfPages
        view.backgroundStyle = .minimal
        view.addTarget(context.coordinator, action: #selector(Coordinator.pageChanged), for: .valueChanged)
        return view
    }

    func updateUIView(_ uiView: UIPageControl, context: Context) {
        uiView.numberOfPages = numberOfPages
        uiView.currentPage = currentPage
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: CustomPageControl

        init(_ parent: CustomPageControl) {
            self.parent = parent
        }

        @objc func pageChanged(sender: UIPageControl) {
            parent.currentPage = sender.currentPage
        }
    }
}
struct NotificationBannerTopEdge<Content: View>: View {
    let content: Content
    let bumpOriginPoint: CGPoint

    init(bumpOriginPoint: CGPoint, @ViewBuilder content: () -> Content) {
        self.bumpOriginPoint = bumpOriginPoint
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let rect = geometry.frame(in: .local)
                let bumpHeight: CGFloat = 20
                let bumpWidth: CGFloat = 30
                let bumpStartX = bumpOriginPoint.x - bumpWidth / 2
                let bumpEndX = bumpOriginPoint.x + bumpWidth / 2
                let cornerRadius: CGFloat = 5
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: max(bumpStartX, 0), y: 0))
                path.addLine(to: CGPoint(x: bumpOriginPoint.x - 5, y: -bumpHeight))
                path.addArc(center: CGPoint(x: bumpOriginPoint.x, y: -bumpHeight), radius: cornerRadius, startAngle: Angle(degrees: 182), endAngle: Angle(degrees: 0), clockwise: false)
//                let curve: CGPoint = .init(x: bumpOriginPoint.x, y: bumpOriginPoint.y)

//                path.addQuadCurve(to: curve, control: CGPoint(x: curve.x, y: curve.y))
                path.addLine(to: CGPoint(x: min(bumpEndX, rect.width), y: 0))
                path.addLine(to: CGPoint(x: rect.width, y: 0))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height))
                path.addLine(to: CGPoint(x: 0, y: rect.height))
                path.closeSubpath()
            }
//            .fill(Color.green)
            .stroke(Color.notificationDividerColor, lineWidth: 0.5)
            .background(content)
        }

    }
}

class NotificationCarouselViewModel: ObservableObject {
    @Published var selectedTabIndex: Int = 0
    @Published var notifications: [NotificationBannerViewModel] = []
    @Published var showingWebView = false
    @Published var webViewURL: URL?

    init() {
        let tappedAction: (URL) -> Void = { [weak self] url in
            self?.webViewURL = url
            self?.showingWebView = true
        }
        self.notifications = [
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

        ].shuffled()
    }
}

struct NotificationCarousel: View {
    @StateObject private var viewModel: NotificationCarouselViewModel = .init()
    @Binding var isPresented: Bool
    private var divider: some View {
        Divider()
            .frame(height: 1)
            .background(Color.notificationDividerColor)
    }

    var body: some View {
        VStack {
            divider
            Group {
                TabView(selection: $viewModel.selectedTabIndex) {
                    ForEach(Array(viewModel.notifications.enumerated()), id: \.element.id) { index, notif in
                        NotificationBanner(viewModel: notif)
                            .tag(index)
                    }
                }
                .onChange(of: viewModel.selectedTabIndex) { oldValue, newValue in
                    let viewedNotification = viewModel.notifications[newValue]
                    EventTracking.trackNotificationSwipedViewed(title: viewedNotification.titleText)
                }

                .tabViewStyle(.page(indexDisplayMode: .never))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .onAppear {
                    let viewedNotification = viewModel.notifications[viewModel.selectedTabIndex]
                }
            }
            HStack {
                CustomPageControl(numberOfPages: viewModel.notifications.count, currentPage: $viewModel.selectedTabIndex)
                    .padding([.top, .bottom], 16)
                    .frame(maxWidth: 100)
                Spacer()
            }
            divider
        }
        .frame(height: 240)
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
        NotificationCarousel(isPresented: .constant(true))
    }
}
