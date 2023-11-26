//
//  HeadingSubheadingImageComponent.swift
//  Encamera
//
//  Created by Alexander Freas on 12.11.23.
//

import SwiftUI
import EncameraCore

struct HeadingSubheadingImageComponent: View {

    private enum Constants {
        static let titleHeight = 48.0
        static let titleContentSpacing = 20.0
        static let subheadingMaxWidth = 255.0
        static let imageSpacingTrailing = 4.0
    }
    var title: String?
    var subheading: String?
    var image: Image?


    var body: some View {
        VStack(alignment: .leading) {
            if let title = title {
                HStack(alignment: .top)  {
                    Text(title)
                        .fontType(.pt24, weight: .bold)
                    Spacer()
                    Group {
                        if let image = image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .opacity(AppConstants.lowOpacity)

                        } else {
                            Color.clear
                        }
                    }.frame(width: 48, height: 48)
                    Spacer().frame(width: Constants.imageSpacingTrailing)
                }.frame(height: Constants.titleHeight)
            }
            if let subheading = subheading {
                Text(subheading)
                    .fontType(.pt14)
                    .frame(maxWidth: Constants.subheadingMaxWidth, alignment: .topLeading)
                Spacer().frame(height: Constants.titleContentSpacing)
            }
        }
    }
}

#Preview {
    HeadingSubheadingImageComponent()
}
