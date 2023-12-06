//
//  OnboardingView.swift
//  Encamera
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI
import EncameraCore

struct OnboardingViewViewModel {

    var screen: OnboardingFlowScreen
    var title: String? = nil
    var subheading: String? = nil
    var progress: (Int, Int) = (0, 0)
    var image: Image? = nil
    var showTopBar: Bool = true
    var bottomButtonTitle: String
    var bottomButtonAction: (() async throws -> Void)?
    var content: ((@escaping () -> Void) -> AnyView)?

}


private enum Constants {
    static let backButtonTextKerning = 0.28
    static let topElementTitleSpacing = 40.0
}


struct OnboardingView<Next>: View where Next: View {
    
    @State var nextActive: Bool = false 
    @Environment(\.dismiss) var dismiss

    var viewModel: OnboardingViewViewModel
    
    let nextScreen: () -> Next?
    
    init(viewModel: OnboardingViewViewModel, @ViewBuilder nextScreen: @escaping () -> Next? = { nil }) {
        self.nextScreen = nextScreen
        self.viewModel = viewModel
    }
    

    var body: some View {
            VStack(alignment: .leading, spacing: 2) {

                if viewModel.showTopBar {
                    HStack {
                        Image("Onboarding-Arrow-Back")
                        Text(L10n.profileSetup)
                            .fontType(.pt14, weight: .bold)
                            .kerning(Constants.backButtonTextKerning)
                            .opacity(AppConstants.lowOpacity)
                        Spacer()
                        if viewModel.progress.1 > 0 {
                            StepIndicator(numberOfItems: viewModel.progress.1, currentItem: viewModel.progress.0)
                        }
                    }.onTapGesture {
                        dismiss()
                    }
                }
                Spacer().frame(height: Constants.topElementTitleSpacing)
                HeadingSubheadingImageComponent(title: viewModel.title, subheading: viewModel.subheading, image: viewModel.image)
                self.viewModel.content?({
                    nextActive = true
                })
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
                }.padding(14)
            }

            .padding(EdgeInsets(top: 0, leading: 10, bottom: 20, trailing: 10))
            .navigationBarHidden(true)
            .gradientBackground()
            .onAppear {
                EventTracking.trackOnboardingViewReached(view: viewModel.screen)
            }
    }
}
//
//
struct OnboardingView_Previews: PreviewProvider {
    
    static var previews: some View {
        NavigationView {
            OnboardingView(viewModel: .init(
                screen: .biometrics,
                title: "Here's the Title",
                subheading: "And the subheading",
                progress: (1, 5),
                image: Image(systemName: "camera"),
                bottomButtonTitle: "Next",
                bottomButtonAction: {
                    
                }) {_ in 
                    AnyView(VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.onboardingIntroHeadingText1)
                            .fontType(.medium, weight: .bold)
                        Text(L10n.onboardingIntroSubheadingText)
                            .fontType(.pt18)
                        Spacer()
                    })
                    
                }, nextScreen: { EmptyView() })
            
        }
        .preferredColorScheme(.dark)
    }
    
}

