//
//  BottomNavigationBar.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import SwiftUI

struct BottomNavigationBar: View {


    


    var body: some View {
                ZStack(alignment: .bottom) {

            VStack {
                HStack {
                    barItem(image: Image("BottomNavigation-Albums"), text: "Albums", isSelected: false)
                    Spacer()
                    barItem(image: Image("BottomNavigation-Settings"), text: "Settings", isSelected: true)
                }
                .padding()
                Spacer().frame(height: getSafeAreaBottom())
            }
            .alignmentGuide(.bottom, computeValue: { dimension in
                dimension[VerticalAlignment.center]
            })
            .background(Color.black.opacity(0.5))
            .clipShape(CustomClipShape(
                cornerRadius: Constants.cornerRadius,
                circleRadius: Constants.radius,
                circlePadding: Constants.circlePadding
            ))

            Button {
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
    private func barItem(image: Image, text: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {

            image

            Text(text)
                .fontType(.pt14, on: .darkBackground,  weight: .bold)

        }.opacity(isSelected ? 0.5 : 1.0)
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

            let circleRect = CGRect(x: rect.midX - circleRadius - circlePadding,
                                    y: -(circleRadius/2 + circlePadding),
                                    width: circleRadius * 2 + circlePadding * 2,
                                    height: circleRadius * 2 + circlePadding * 2)
            if #available(iOS 17.0, *) {
                return path.subtracting(Path(ellipseIn: circleRect))
            }

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
            BottomNavigationBar()
        }.ignoresSafeArea()
    }
}
