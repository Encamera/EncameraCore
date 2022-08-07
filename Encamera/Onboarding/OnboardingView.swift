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
    var bottomButtonAction: (() throws -> Void)?
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
                self.viewModel.content?()
                Spacer()
                NavigationLink(isActive: $nextActive) {
                    nextScreen()
                } label: {
                }.isDetailLink(false)
                Button(viewModel.bottomButtonTitle, action: {
                    do {
                        try viewModel.bottomButtonAction?()
                        nextActive = true
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
//
//
struct OnboardingView_Previews: PreviewProvider {
    
    
    @ViewBuilder static func storageButton(imageName: String, text: String, isSelected: Binding<Bool>, action: @escaping () -> Void) -> some View {
        let background = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let output = Button(action: action, label: {
            
            VStack {
                Image(systemName: imageName).resizable()
                    .aspectRatio(contentMode: .fit)
                
                Text(text)
            }.padding()
        })
        .frame(width: 100, height: 100)
        
        if isSelected.wrappedValue == true {
            output
                .foregroundColor(Color.black)
                .background(background.fill(Color.white))

        } else {
            output
                .overlay(background.stroke(Color.gray, lineWidth: 3))

        }
    }
    
    
    static var previews: some View {
        
        
        var selected: StorageType = .local

        OnboardingView(viewModel: .init(title: "Storage Settings",
                                        subheading: "Where do you want to store media for files encrypted with this key?",
                                        image: Image(systemName: ""),
                                        bottomButtonTitle: "Next") {
                           } content: {
                               AnyView(
                                HStack {
                                    

                                    ForEach(StorageType.allCases) { data in
                                        let binding = Binding {
                                            data == selected
                                        } set: { value in
                                            selected = data
                                        }
                                        storageButton(imageName: data.iconName, text: data.title, isSelected: binding) {
                                            
                                        }
                                    }
                                    
                                })
                            }, nextScreen: { EmptyView() })
                           
    }
    
}

