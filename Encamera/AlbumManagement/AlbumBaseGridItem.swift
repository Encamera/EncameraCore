//
//  AlbumBaseGridItem.swift
//  Encamera
//
//  Created by Alexander Freas on 25.10.23.
//

import Foundation
import SwiftUI

struct AlbumBaseGridItem<SubheadingView: View>: View {

    var image: Image?
    var title: String
    var subheadingView: SubheadingView
    var width: CGFloat
    var strokeStyle: StrokeStyle? = nil
    var shouldResizeImage: Bool = true

    init(image: Image? = nil, uiImage: UIImage? = nil, title: String, @ViewBuilder subheadingView: () -> SubheadingView, width: CGFloat, strokeStyle: StrokeStyle? = nil, shouldResizeImage: Bool = true) {
        if let image {
            self.image = image
        }
        if let uiImage {
            self.image = Image(uiImage: uiImage)
        }
        self.title = title
        self.subheadingView = subheadingView()
        self.width = width
        self.strokeStyle = strokeStyle
        self.shouldResizeImage = shouldResizeImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            clipShape
                .stroke(Color.white.opacity(0.3), style: strokeStyle ?? StrokeStyle(lineWidth: 0))
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
                        ZStack {
                            Color.inputFieldBackgroundColor
                            Image("NoImage-Icon")
                        }
                    }
                }
                .clipShape(clipShape)
                .frame(width: width, height: width)
                .padding(.bottom, 12)

            Text(title)
                .fontType(.pt14, weight: .bold) // replace with actual font

            subheadingView
                .frame(height: 20)
                .lineLimit(1, reservesSpace: true)
                .fontType(.pt14) // replace with actual font
                .clipped()
        }
    }

    private var clipShape: some Shape {
        RoundedRectangle(cornerRadius: 10, style: .circular)
    }
}
