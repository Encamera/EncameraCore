//
//  BottomNavigationBar.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import SwiftUI
import EncameraCore

struct BottomNavigationBar: View {

    enum ButtonItem {
        case albums
        case settings
        case camera
    }

    @Binding var selectedItem: ButtonItem

    var body: some View {
        ZStack(alignment: .bottom) {

            VStack {
                HStack {
                    barItem(image: Image("BottomNavigation-Albums"), text: "Albums", item: .albums)
                    Spacer()
                    barItem(image: Image("BottomNavigation-Settings"), text: "Settings", item: .settings)
                }
                .padding(.init(top: 15.0, leading: 35.0, bottom: 15.0, trailing: 35.0))
                Spacer().frame(height: 0) // Removed the extra space for safe area
            }
            .alignmentGuide(.bottom, computeValue: { dimension in
                dimension[VerticalAlignment.center]
            })

            .clipShape(CustomClipShape(
                cornerRadius: Constants.cornerRadius,
                circleRadius: Constants.radius,
                circlePadding: Constants.circlePadding
            ))
            .padding(.bottom, getSafeAreaBottom()) // Add padding for the safe area
            .background(
                .ultraThinMaterial
            )

            Button {
                withAnimation {
                    selectedItem = .camera
                }
                EventTracking.trackOpenedCameraFromBottomBar()
            } label: {
                ZStack {
                    Circle()
                        .foregroundColor(Color.actionYellowGreen)
                        .frame(width: Constants.radius * 2, height: Constants.radius * 2)
                    Image("BottomNavigation-Camera")
                }
            }

        }
    }


    @ViewBuilder
    private func barItem(image: Image, text: String, item: ButtonItem) -> some View {
        Button {
            selectedItem = item
        } label: {
            HStack(spacing: 8) {
                image
                Text(text)
                    .fontType(.pt14, on: .darkBackground, weight: .bold)
            }.opacity(selectedItem == item ? 1.0 : 0.5)

        }
    }

    private enum Constants {
        static let radius = 30.0
        static let circlePadding = 4.0
        static let cornerRadius = 16.0
    }

    private struct CustomClipShape: Shape {
        let cornerRadius: CGFloat
        let circleRadius: CGFloat
        let circlePadding: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()

            path.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
            //probably need to use geo reader to get the proper position of this in the parent view
//            if #available(iOS 17.0, *) {
//                let circleRect = CGRect(x: rect.midX - circleRadius - circlePadding,
//                                        y: -(circleRadius + circlePadding),
//                                        width: circleRadius * 2 + circlePadding * 2,
//                                        height: circleRadius * 2 + circlePadding * 2)
//                return path.subtracting(Path(ellipseIn: circleRect))
//            }

            return path
        }
    }

}

#Preview {
    ZStack {
        Color.orange
            .gradientBackground()
        VStack {
            Spacer()
            BottomNavigationBar(selectedItem: .constant(.albums))
        }
    }.ignoresSafeArea()
}
