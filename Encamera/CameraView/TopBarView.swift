//
//  TopBarView.swift
//  Encamera
//
//  Created by Alexander Freas on 26.04.23.
//

import Foundation
import SwiftUI
import AVFoundation
import EncameraCore



struct TopBarView: View {
    @Binding var showingKeySelection: Bool
    
    @Binding var isRecordingVideo: Bool
    @Binding var recordingDuration: CMTime
    @Binding var currentKeyName: String
    @Binding var flashMode: AVCaptureDevice.FlashMode
    var flashButtonPressed: () -> ()

    var body: some View {
        ZStack {
            HStack {
                HStack {
                    Button {
                        showingKeySelection.toggle()
                    } label: {
                        Image(systemName: "key.fill")
                            .frame(width: 30, height: 44)
                            .symbolRenderingMode(.monochrome)
                            .foregroundColor(.foregroundSecondary)
                        
                        Text(currentKeyName)
                            
                            .frame(minWidth: 70)
                            .fontType(.small, on: .elevated)
                        Spacer().frame(width: 10)


                    }
                    .rotateForOrientation()
                }
                .background(Color.white)
                .cornerRadius(30)
                Spacer()

                Button(action: {
                    flashButtonPressed()
                }, label: {
                    Image(systemName: flashMode.systemIconForMode)
                        .foregroundColor(flashMode.colorForMode)
                        .frame(width: 44, height: 44)
                })
                .rotateForOrientation()
            }
            
            .tint(.white)

            if isRecordingVideo {
                Text(recordingDuration.durationText)
                    .fontType(.small)
                    .padding(5)
                    .background(Color.videoRecordingIndicator)
                    .cornerRadius(10)
            }
        }
    }
}

struct TopBarView_Previews: PreviewProvider {
    static var previews: some View {
        TopBarView(showingKeySelection: .constant(false), isRecordingVideo: .constant(false), recordingDuration: .constant(.zero), currentKeyName: .constant("Test"), flashMode: .constant(.auto), flashButtonPressed: {})
            .previewLayout(.sizeThatFits)
    }
}
