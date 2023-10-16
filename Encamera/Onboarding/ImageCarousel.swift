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
                                        .frame(width: frame.width * 0.90, height: frame.height * 0.7)

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
                                .tag(index)  // Add this line to tag the view with the index
                            }
                        }
                    }
                    .allowsHitTesting(false)  // Add this line to disable user interaction on the ScrollView
                    .onTapGesture {
                        currentScrolledToImage = 0
                        value.scrollTo(currentScrolledToImage, anchor: .leading)
                    }

                    .onChange(of: currentScrolledToImage) { newValue in
                        if newValue < carouselItems.count - 1 {
                            autoScrolling = true
                        } else {
                            autoScrolling = false
                        }
                    }
                    .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                        if autoScrolling {
                            withAnimation {
                                currentScrolledToImage += 1
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
