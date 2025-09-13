//
//  NewOnboardingView.swift
//  Encamera
//
//  Created by Alexander Freas on 04.02.24.
//

import SwiftUI
import EncameraCore

struct NewOnboardingViewViewModel {

    var screen: OnboardingFlowScreen
    var title: String? = nil
    var subheading: String? = nil
    var progress: (Int, Int) = (0, 0)
    var image: Image? = nil
    var showTopBar: Bool = true
    var bottomButtonTitle: String?
    var bottomButtonAction: (() async throws -> Void)?
    var secondaryButtonTitle: String? = nil
    var secondaryButtonAction: (() async throws -> Void)?
    var content: ((@escaping () -> Void) -> AnyView)?

}


private enum Constants {
    static let backButtonTextKerning = 0.28
    static let topElementTitleSpacing = 40.0
}


struct NewOnboardingView: View {

    @State var nextActive: Bool = false
    @Environment(\.dismiss) private var dismiss

    var viewModel: NewOnboardingViewViewModel

    init(viewModel: NewOnboardingViewViewModel) {
        self.viewModel = viewModel
    }


    var body: some View {
            VStack(spacing: 2) {

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
                HeadingSubheadingImageComponent(title: viewModel.title, subheading: viewModel.subheading, image: viewModel.image)
                self.viewModel.content?({
                    nextActive = true
                })
                Spacer()
                DualButtonComponent(nextActive: $nextActive,
                                      bottomButtonTitle: viewModel.bottomButtonTitle,
                                      bottomButtonAction: viewModel.bottomButtonAction,
                                      secondaryButtonTitle: viewModel.secondaryButtonTitle,
                                      secondaryButtonAction: viewModel.secondaryButtonAction)
            }
            .frame(maxWidth: .infinity)
            .navigationBarHidden(true)
            .gradientBackground()
            .onAppear {
                EventTracking.trackOnboardingViewReached(view: viewModel.screen, new: true)
            }
    }
}
