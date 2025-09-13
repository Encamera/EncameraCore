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
        VStack {
            GeometryReader { geo in
                ScrollViewReader { value in
                    let frame = geo.frame(in: .local)
                    ZStack {
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
                                                .padding(.bottom, 32)
                                            Group {
                                                Text(image.heading)
                                                    .fontType(.medium, weight: .bold)
                                                    .lineLimit(2, reservesSpace: true)
                                                Text(image.subheading)
                                                    .fontType(.pt18)
                                                    .lineLimit(2, reservesSpace: true)
                                            }
                                            .multilineTextAlignment(.center)

                                        }
                                        .frame(width: frame.width)
                                        .tag(index)

                                    }
                                }
                            }
                            .allowsHitTesting(false)
                            .onChange(of: currentScrolledToImage, perform: { newImage in
                                withAnimation {
                                    value.scrollTo(newImage, anchor: .leading)
                                }
                            })
                        }
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture()
                                    .onEnded({ gesture in
                                        if gesture.translation.width > 0 {
                                            // Swiped right
                                            if currentScrolledToImage > 0 {
                                                currentScrolledToImage -= 1
                                            }
                                        } else if gesture.translation.width < 0 {
                                            // Swiped left
                                            if currentScrolledToImage < carouselItems.count - 1 {
                                                currentScrolledToImage += 1
                                            }
                                        }
                                    })
                            )
                    }
                }
            }

            Spacer().frame(height: 32)
            ImageStepIndicator(activeIndex: $currentScrolledToImage, numberOfItems: carouselItems.count)
                .onTapGesture {
                    withAnimation {
                        currentScrolledToImage += 1
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
