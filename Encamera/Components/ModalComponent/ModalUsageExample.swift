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
                Image("EncryptionKeyBackupHeading")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .foregroundColor(.orange)
                
                Text("Back up your Encryption Key")
                    .fontType(.pt24, weight: .bold)

                VStack(spacing: 16) {
                    Text("Your photos are protected with a unique encryption key. This is the only way to recover your images if you switch devices or reinstall the app.")
                        .fontType(.pt16)
                        .multilineTextAlignment(.center)
                    
                    Text("We cannot help you recover lost photos without this key.")
                        .fontType(.pt16, weight: .bold)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                
                Button("View the Key") {
                    showModal = false
                    // Handle action
                }
                .primaryButton()
            }
            .padding(.vertical, 40)
        }
    }
}

#Preview {
    ModalUsageExample()
}
