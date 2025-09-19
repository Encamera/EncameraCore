//
//  ModalUsageExample.swift
//  Encamera
//
//  Created by Assistant on 19.09.25.
//

import SwiftUI
import EncameraCore

struct ModalUsageExample: View {
    @State private var showModal = false
    @State private var showSecondModal = false
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Modal Component Examples")
                .font(.title)
                .fontWeight(.bold)
            
            Button("Show Encryption Key Modal") {
                showModal = true
            }
            .primaryButton()
            
            Button("Show Custom Content Modal") {
                showSecondModal = true
            }
            .secondaryButton()
        }
        .gradientBackground()
        .reusableModal(isPresented: $showModal) {
            // Example 1: Encryption Key Backup Modal (matching the screenshot)
            VStack(spacing: 24) {
                Image(systemName: "key.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .foregroundColor(.orange)
                
                Text("Back up your Encryption Key")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                VStack(spacing: 16) {
                    Text("Your photos are protected with a unique encryption key. This is the only way to recover your images if you switch devices or reinstall the app.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    
                    Text("We cannot help you recover lost photos without this key.")
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                
                Button("View the Key") {
                    showModal = false
                    // Handle action
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.black)
                .cornerRadius(12)
                .fontWeight(.semibold)
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 40)
        }
        .reusableModal(isPresented: $showSecondModal) {
            // Example 2: Custom Content Modal
            VStack(spacing: 20) {
                Image(systemName: "star.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 50)
                    .foregroundColor(.yellow)
                
                Text("Custom Modal")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("This modal can contain any custom content you want!")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                
                HStack(spacing: 15) {
                    Button("Cancel") {
                        showSecondModal = false
                    }
                    .secondaryButton()
                    
                    Button("Confirm") {
                        showSecondModal = false
                    }
                    .primaryButton()
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 30)
        }
    }
}

#Preview {
    ModalUsageExample()
}
