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


struct NotificationCarousel: View {
    @Binding var isPresented: Bool
    @State private var selectedTabIndex: Int = 0
    @State private var notifications: [NotificationBannerViewModel]

    init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
        self.notifications = [
            .init(image: Image("NotificationBanner-ShieldCheck"), titleText: L10n.notificationBannerTitle, bodyText: L10n.notificationBannerBody, buttonText: nil, id: 0),
            .init(image: Image("Telegram-Logo"), titleText: L10n.telegramGroupJoinTitle, bodyText: L10n.telegramGroupJoinBody, buttonText: L10n.telegramGroupJoinButtonText, buttonUrl: URL(string: "https://t.me/encamera_app")!, id: 1),
            .init(image: Image("NotificationBanner-Widget"), titleText: L10n.installWidgetTitle, bodyText: L10n.installWidgetBody, buttonText: L10n.installWidgetButtonText, buttonUrl: URL(string: "https://vimeo.com/896507875")!, id: 2),
            .init(image: Image("NotificationBanner-Survey"), titleText: L10n.takeSurveyTitle, bodyText: L10n.takeSurveyBody, buttonText: L10n.takeSurveyButtonText, buttonUrl: URL(string: "")!, id: 3)
        ].shuffled()
    }

    private var divider: some View {
        Divider()
            .frame(height: 1)
            .background(Color.notificationDividerColor)

    }

    var body: some View {
                VStack {
                    divider
                Group {
                    TabView(selection: $selectedTabIndex) {
                        ForEach(Array(notifications.enumerated()), id: \.element.id) { index, notif in
                            NotificationBanner(viewModel: notif)
                                .tag(index)
                        }
                    }
                    .onChange(of: selectedTabIndex, { oldValue, newValue in
                        let viewedNotification = notifications[newValue]
                        EventTracking.trackNotificationViewed(title: viewedNotification.titleText)
                    })

                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .never))
                    .onAppear {
                        let viewedNotification = notifications[selectedTabIndex]
                        EventTracking.trackNotificationViewed(title: viewedNotification.titleText)
                    }
                }
                    HStack {
                        CustomPageControl(numberOfPages: notifications.count, currentPage: $selectedTabIndex)
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
    }
}

#Preview {
    ZStack {
        Color.black
        NotificationCarousel(isPresented: .constant(true))
    }
}
