//
//  OnboardingImageCarousel.swift
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
struct OnboardingImageCarousel: View {

    @Binding var currentScrolledToImage: Int

    init(currentScrolledToImage: Binding<Int>) {
        self.carouselItems = [

            ImageCarouselItem(imageID: "Onboarding-Image-1", heading: L10n.OnboardingCarousel.headingText1, subheading: L10n.OnboardingCarousel.subheadingText1),
            ImageCarouselItem(imageID: "Onboarding-Image-2", heading: L10n.OnboardingCarousel.headingText2, subheading: L10n.OnboardingCarousel.subheadingText2),
            ImageCarouselItem(imageID: "Onboarding-Image-3", heading: L10n.OnboardingCarousel.headingText3, subheading: L10n.OnboardingCarousel.subheadingText3),
        ]
        _currentScrolledToImage = currentScrolledToImage
    }


    private var carouselItems: [ImageCarouselItem]

    var body: some View {
        VStack(spacing: 16) {
            // Modern TabView approach - no GeometryReader needed!
            TabView(selection: $currentScrolledToImage) {
                ForEach(carouselItems.indices, id: \.self) { index in
                    let image = carouselItems[index]
                    VStack(spacing: 16) {
                        Image(image.imageID)
                            .resizable()
                            .scaledToFill()
                            .clipped()
                            .mask(
                                LinearGradient(
                                    gradient: Gradient(stops: [
                                        .init(color: .black, location: 0.0),
                                        .init(color: .black, location: 0.6),
                                        .init(color: .clear, location: 1.0)
                                    ]),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        
                        VStack(spacing: 8) {
                            Text(image.heading)
                                .fontType(.medium, weight: .bold)
                                .lineLimit(2, reservesSpace: true)
                            Text(image.subheading)
                                .fontType(.pt14)
                                .lineLimit(2, reservesSpace: true)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never)) // Hide built-in page indicators
            .animation(.easeInOut(duration: 0.3), value: currentScrolledToImage) // Smooth animation on programmatic changes
            
            ImageStepIndicator(activeIndex: $currentScrolledToImage, numberOfItems: carouselItems.count)
                .onTapGesture {
                    withAnimation {
                        if currentScrolledToImage < carouselItems.count - 1 {
                            currentScrolledToImage += 1
                        }
                    }
                }
        }
    }
}

@available(iOS 17.0, *)
struct ImageCarousel_Previews: PreviewProvider {

    static var previews: some View {
        OnboardingImageCarousel(currentScrolledToImage: .constant(0))
    }
}
