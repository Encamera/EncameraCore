//
//  ImageCarousel.swift
//  Encamera
//
//  Created by Alexander Freas on 16.10.23.
//

import Foundation
import EncameraCore
import SwiftUI

private class ImageCarouselItem: Identifiable {
    let imageID: String
    let heading: String
    let subheading: String

    init(imageID: String, heading: String, subheading: String) {
        self.imageID = imageID
        self.heading = heading
        self.subheading = subheading
    }
}

//@available(iOS 17.0, *)
struct ImageCarousel: View {

    @State var currentScrolledToImage = 0
    @State private var autoScrolling = true

    private var carouselItems = [

        ImageCarouselItem(imageID: "Onboarding-Image-1", heading: L10n.onboardingIntroHeadingText1, subheading: L10n.onboardingIntroSubheadingText),
        ImageCarouselItem(imageID: "Onboarding-Image-2", heading: L10n.keyBasedEncryption, subheading: L10n.encryptionExplanation),
        ImageCarouselItem(imageID: "Onboarding-Image-3", heading: L10n.noTrackingOnboardingExplanation, subheading: L10n.noTrackingExplanation),
    ]

    var body: some View {
        GeometryReader { geo in

            ScrollViewReader { value in
                let frame = geo.frame(in: .local)
                VStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(carouselItems.indices, id: \.self) { index in
                                let image = carouselItems[index]
                                VStack {
                                    Color.clear
                                        .background {
                                            Image(image.imageID)
                                                .resizable()
                                                .scaledToFill()
                                        }.clipShape(RoundedRectangle(cornerSize: .init(width: 30, height: 30)))
                                        .frame(width: frame.width, height: frame.height * 0.7)

                                    Group {
                                        Text(image.heading)
                                            .fontType(.medium, weight: .bold)
                                            .lineLimit(2, reservesSpace: true)
                                        Text(image.subheading)
                                            .fontType(.small)
                                    }
                                    .multilineTextAlignment(.center)

                                }
                                .frame(width: frame.width)
                                .tag(index) 
                            }
                        }
                    }
                    
                    .allowsHitTesting(false)
                    .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
                        if autoScrolling {
                            withAnimation {
                                currentScrolledToImage = (currentScrolledToImage + 1) % carouselItems.count
                                value.scrollTo(currentScrolledToImage, anchor: .leading)
                            }
                        }
                    }
                }
                Spacer().frame(height: 32)
                ImageStepIndicator(activeIndex: $currentScrolledToImage, numberOfItems: carouselItems.count)
            }
        }
    }
}

@available(iOS 17.0, *)
struct ImageCarousel_Previews: PreviewProvider {

    static var previews: some View {
        ImageCarousel()
    }
}
