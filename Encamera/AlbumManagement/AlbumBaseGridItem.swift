//
//  AlbumBaseGridItem.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import Foundation
import SwiftUI

struct AlbumBaseGridItem: View {

    var image: Image?
    var title: String
    var subheading: String?
    var width: CGFloat
    var strokeStyle: StrokeStyle? = nil
    var shouldResizeImage: Bool = true

    init(image: Image? = nil, uiImage: UIImage? = nil, title: String, subheading: String? = nil, width: CGFloat, strokeStyle: StrokeStyle? = nil, shouldResizeImage: Bool = true) {
        if let image {
            self.image = image
        }
        if let uiImage {
            self.image = Image(uiImage: uiImage)
        }
        self.title = title
        self.subheading = subheading
        self.width = width
        self.strokeStyle = strokeStyle
        self.shouldResizeImage = shouldResizeImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .stroke(style: strokeStyle ?? StrokeStyle(lineWidth: 0))
                .background {
                if let image = image {
                    if shouldResizeImage {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        image
                    }

                } else {
                    Color.inputFieldBackgroundColor
                }
            }
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .circular))
            .padding(.bottom, 12)


            Text(title)
                .fontType(.pt14, weight: .bold) // replace with actual font

//            if let subheading = subheading {
                Text(subheading ?? "")
                .lineLimit(1, reservesSpace: true)
                    .fontType(.pt14) // replace with actual font
//            }
        }
    }
}
