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
                .clipShape(RoundedRectangle(cornerRadius: 16.0))

                Button {
                } label: {
                    ZStack {
                        Circle()
                            .foregroundColor(Color.actionYellowGreen)
                            .frame(width: 60, height: 60)
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
}

#Preview {
    ZStack {
        Color.clear
            .gradientBackground()
        VStack {
            Spacer()
            BottomNavigationBar()
        }.ignoresSafeArea()
    }
}
