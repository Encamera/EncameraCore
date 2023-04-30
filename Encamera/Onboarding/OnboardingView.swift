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
    var content: (() -> AnyView)?
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
                if let subheading = viewModel.subheading {
                    Text(subheading)
                        .fontType(.small)
                    Spacer().frame(height: 20)
                }
                self.viewModel.content?()
                    
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
                    Spacer()
                    if viewModel.progress.1 > 0 {
                        ProgressViewCircular(progress: viewModel.progress.0, total: viewModel.progress.1)
                    }
                }

            }
            
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 10))
            .navigationTitle(viewModel.title)
            .navigationBarHidden(viewModel.title == "" ? true : false)
            .background(Color.background)
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
                progress: (1, 3),
                image: Image(systemName: "camera"),
                bottomButtonTitle: "Next",
                bottomButtonAction: {
                    
                }) {
                    AnyView(VStack(alignment: .leading, spacing: 10) {
                        Image("EncameraBanner")
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text(L10n.encryptionExplanation)
                            .fontType(.medium, weight: .bold)
                        Text(L10n.encameraEncryptsAllDataItCreatesKeepingYourDataSafeFromThePryingEyesOfAIMediaAnalysisAndOtherViolationsOfPrivacy)
                            .fontType(.small)
                        Text(L10n.keyBasedEncryption🔑)
                            .fontType(.medium, weight: .bold)
                        Text(L10n.yourMediaIsSafelySecuredBehindAKeyAndStoredLocallyOnYourDeviceOrCloudOfChoice)
                        Text(L10n.forYourEyesOnly👀)
                            .fontType(.medium, weight: .bold)
                        Text(L10n.noTrackingExplanation)
                            .fontType(.small)
                        Spacer()
                    })
                    
                }, nextScreen: { EmptyView() })
            
        }
        .preferredColorScheme(.dark)
    }
    
}

