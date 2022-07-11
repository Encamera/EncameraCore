//
//  AuthenticationView.swift
//  Shadowpix
//
//  Created by Alexander Freas on 10.07.22.
//

import SwiftUI

struct AuthenticationView: View {
    
    class AuthenticationViewModel: ObservableObject {
        @Published var password: String = ""
    }
    
    @ObservedObject var viewModel: AuthenticationViewModel
    
    var body: some View {
        VStack {
            
            TextField("Password", text: $viewModel.password)
            Button("Unlock") {
                
            }
            Spacer()
        }
        .padding()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color.green)
        
    }
}

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticationView(viewModel: .init())
    }
}
