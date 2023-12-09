//
//  NotificationBanner.swift
//  Encamera
//
//  Created by Alexander Freas on 09.12.23.
//

import SwiftUI

struct NotificationBanner: View {

    @Binding var isPresented: Bool
    var image: Image? = Image("NotificationBanner-Lock")
    var titleText: String = "Add Widget"
    var bodyText: String = "Non explicabo officia aut odit ex  eum ipsum libero."
    var buttonText: String = "Add Widget"
    var body: some View {
        if isPresented {
            GeometryReader { geo in

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(titleText)
                            .fontType(.pt16, weight: .bold)
                            .foregroundColor(.white)
                        Text(bodyText)
                            .fontType(.pt14)
                            .opacity(0.80)
                        Spacer()
                        Text(buttonText)
                            .fontType(.pt14, on: .textButton, weight: .bold)
                    }
                    .padding(24)
                    .if(image != nil, transform: { view in
                        view.frame(width: (geo.size.width / 3)*2)

                    })
                    if let image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width / 3 - 24)
                            .padding(.trailing, 24)
                            .padding(.top, 24)
                            .padding(.bottom, 24)
                    }
                }
            }
            .frame(height: 165)
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.09, green: 0.09, blue: 0.09))
            .transition(.opacity)

        } else {
            EmptyView()
        }
    }
}

#Preview {
    NotificationBanner(isPresented: .constant(true))
}
