//
//  OnboardingView.swift
//  Encamera
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
        var bottomButtonAction: () throws -> Void
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
                Button(viewModel.bottomButtonTitle, action: {
                    do {
                        try viewModel.bottomButtonAction()
                    } catch {
                        print("Error on bottom button action", error)
                    }
                })
                    .frame(width: frame.width)
                    .primaryButton()
                Spacer().frame(height: 50.0)
            }.foregroundColor(.white)
        }.padding().background(Color.black)
    }
}


struct OnboardingView_Previews: PreviewProvider {
    
    
    
    
    static var previews: some View {
        
        OnboardingView(viewModel: .init(title: "Setup Image Key", subheading:
                                            """
Set the name for the first key.

This is different from your password, and will be used to encrypt data.

You can have multiple keys for different purposes, e.g. one named "Banking" and another "Personal".
""", image: Image(systemName: "key.fill"), bottomButtonTitle: "Save Key", bottomButtonAction: {
        })) {
            VStack {
                TextField("Name", text: .constant("")).inputTextField()
            }
        }
    }
}
