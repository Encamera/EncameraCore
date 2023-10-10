//
//  OnboardingView.swift
//  Encamera
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI
import EncameraCore

struct OnboardingViewViewModel {
    var title: String
    var subheading: String?
    var progress: (Int, Int) = (0, 0)
    var image: Image
    var bottomButtonTitle: String
    var bottomButtonAction: (() async throws -> Void)?
    var content: ((@escaping () -> Void) -> AnyView)?
}


private enum Constants {
    static let lowOpacity = 0.4
    static let backButtonTextKerning = 0.28
    static let topElementTitleSpacing = 40.0
    static let titleHeight = 48.0
    static let titleContentSpacing = 20.0
    static let subheadingMaxWidth = 255.0
    static let imageSpacingTrailing = 4.0
}


struct OnboardingView<Next>: View where Next: View {
    
    @State var nextActive: Bool = false 
    var viewModel: OnboardingViewViewModel
    
    let nextScreen: () -> Next?
    
    init(viewModel: OnboardingViewViewModel, @ViewBuilder nextScreen: @escaping () -> Next? = { nil }) {
        self.nextScreen = nextScreen
        self.viewModel = viewModel
    }
    

    var body: some View {
            VStack(alignment: .leading, spacing: 2) {

                HStack {
                    Image("Onboarding-Arrow-Back")
                    Text("PROFILE SETUP")
                        .fontType(.extraSmall, weight: .bold)
                        .kerning(Constants.backButtonTextKerning)
                        .opacity(Constants.lowOpacity)
                    Spacer()
                    if viewModel.progress.1 > 0 {
                        StepIndicator(numberOfItems: viewModel.progress.1, currentItem: viewModel.progress.0)
                    }
                }
                Spacer().frame(height: Constants.topElementTitleSpacing)
                HStack(alignment: .top)  {
                    Text(viewModel.title)
                        .fontType(.mediumSmall, weight: .bold)
                    Spacer()
                    viewModel.image
                        .resizable()
                        .opacity(Constants.lowOpacity)
                        .frame(width: 48, height: 48)
                    Spacer().frame(width: Constants.imageSpacingTrailing)
                }.frame(height: Constants.titleHeight)
                if let subheading = viewModel.subheading {
                    Text(subheading)
                            .fontType(.extraSmall)

                            .frame(maxWidth: Constants.subheadingMaxWidth, alignment: .topLeading)

                    Spacer().frame(height: Constants.titleContentSpacing)
                }

                self.viewModel.content?({
                    nextActive = true
                })
                    .fixedSize(horizontal: false, vertical: true).padding(0)
                    
                Spacer()
                NavigationLink(isActive: $nextActive) {
                    nextScreen()
                } label: {
                }.isDetailLink(false)
                Spacer()
                HStack {
                    Button(viewModel.bottomButtonTitle) {
                        Task {
                            do {
                                try await viewModel.bottomButtonAction?()
                                nextActive = true
                            } catch {
                                print("Error on bottom button action", error)
                            }
                        }
                    }
                    .primaryButton()
                }

            }
            
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 10))
            .navigationBarHidden(true)
            .background {
                ZStack {
                    Color.background
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image("Onboarding-Background")
                        }
                    }
                }.ignoresSafeArea()
            }

    }
}
//
//
struct OnboardingView_Previews: PreviewProvider {
    
    static var previews: some View {
        NavigationView {
            OnboardingView(viewModel: .init(
                title: "",
                subheading: "",
                progress: (1, 5),
                image: Image(systemName: "camera"),
                bottomButtonTitle: "Next",
                bottomButtonAction: {
                    
                }) {_ in 
                    AnyView(VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.onboardingIntroHeadingText1)
                            .fontType(.medium, weight: .bold)
                        Text(L10n.onboardingIntroSubheadingText)
                            .fontType(.small)
                        Spacer()
                    })
                    
                }, nextScreen: { EmptyView() })
            
        }
        .preferredColorScheme(.dark)
    }
    
}

