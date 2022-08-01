//
//  OnboardingView.swift
//  Encamera
//
//  Created by Alexander Freas on 13.07.22.
//

import SwiftUI

struct OnboardingViewViewModel {
    var title: String
    var subheading: String
    var image: Image
    var bottomButtonTitle: String
    var bottomButtonAction: () throws -> Void
}

struct OnboardingView<Content, Next>: View where Content: View, Next: View {
    
    
    
    var viewModel: OnboardingViewViewModel
    
    let content: (() -> Content)
    let nextScreen: (() -> Next)
    
    init(viewModel: OnboardingViewViewModel, @ViewBuilder nextScreen: @escaping () -> Next, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.nextScreen = nextScreen
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
                NavigationLink {
                    nextScreen()
                } label: {
                    
                    Button(viewModel.bottomButtonTitle, action: {
                        do {
                            try viewModel.bottomButtonAction()
                        } catch {
                            print("Error on bottom button action", error)
                        }
                    })
                    .frame(width: frame.width)
                    .primaryButton()
                }
                Spacer().frame(height: 50.0)
            }.foregroundColor(.white)
        }.padding().background(Color.black)
    }
}
//
//
//struct OnboardingView_Previews: PreviewProvider {
//
//
//
//
//    static var previews: some View {
//
//        OnboardingView(viewModel: .init(title: "Setup Image Key", subheading:
//                                            """
//Set the name for the first key.
//
//This is different from your password, and will be used to encrypt data.
//
//You can have multiple keys for different purposes, e.g. one named "Banking" and another "Personal".
//""", image: Image(systemName: "key.fill"), bottomButtonTitle: "Save Key", bottomButtonAction: {
//        })) {
//            VStack {
//                TextField("Name", text: .constant("")).inputTextField()
//            }
//        }
//    }
//}
