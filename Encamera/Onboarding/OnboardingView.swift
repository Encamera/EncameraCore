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
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.subheading)
                
//
//                viewModel.image
//                    .resizable()
//                    .aspectRatio(contentMode: .fit)
                //                    .frame(width: frame.width, height: frame.width)
                Spacer().frame(height: 20)
                self.viewModel.content?()
                Spacer()
                NavigationLink(isActive: $nextActive) {
                    nextScreen()
                } label: {
                }.isDetailLink(false)
                Spacer()
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
            
        }.padding().background(Color.black).navigationTitle(viewModel.title)
            
    }
}
//
//
struct OnboardingView_Previews: PreviewProvider {
    
    static var previews: some View {
        NavigationView {
            OnboardingView(viewModel: .init(title: "Storage Settings",
                                            subheading: """
               Where do you want to store media for files encrypted with this key?
               
               Each key will store data in its own directory.
               """,
                                            image: Image(systemName: ""),
                                            bottomButtonTitle: "Next") {
            } content: {
                AnyView(
                    
                    VStack(spacing: 20) {
                        
                        ForEach(StorageType.allCases) { data in
                            StorageTypeOptionItemView(
                                storageType: data,
                                availability: .available,
                                isSelected: .constant(false))
                        }
                    }
                )
                
            }, nextScreen: { EmptyView() })
            
        }
    }
    
}

