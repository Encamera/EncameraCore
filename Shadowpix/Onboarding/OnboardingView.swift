//
//  OnboardingView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI

struct OnboardingView<Content>: View where Content: View {
    
    struct OnboardingViewModel {
        var title: String
        var subheading: String
        var image: Image
        var bottomButtonTitle: String
        var bottomButtonAction: () -> Void
    }
    
    var viewModel: OnboardingViewModel
    
    let content: (() -> Content)
    
    init(viewModel: OnboardingViewModel, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.viewModel = viewModel
    }
    
    
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            VStack(alignment: .leading) {
                Text(viewModel.title).titleText()
                    .font(.system(.title))
                Text(viewModel.subheading)
                
//
//                viewModel.image
//                    .resizable()
//                    .aspectRatio(contentMode: .fit)
//                    .frame(width: frame.width, height: frame.width)
                self.content()
                Spacer()
                Button(viewModel.bottomButtonTitle, action: viewModel.bottomButtonAction)
                    .frame(width: frame.width)
                    .primaryButton()
                Spacer().frame(height: 50.0)
            }.foregroundColor(.white)
        }.padding().background(Color.black)
    }
}


struct OnboardingView_Previews: PreviewProvider {
    
 
    
    
    static var previews: some View {
        OnboardingView(viewModel: .init(title: "You're all set!", subheading: "", image: Image(systemName: "faceid"), bottomButtonTitle: "Done", bottomButtonAction: {
            
        })) {
            
        }
    }
}
