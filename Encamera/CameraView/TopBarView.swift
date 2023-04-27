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
    var settingsButtonTapped: () -> ()
    var flashButtonPressed: () -> ()
    let cornerRadius = 30.0
    var body: some View {
        ZStack {
                HStack(spacing: 0.0) {
                    HStack(spacing: 0.0) {
                        Button {
                            self.settingsButtonTapped()
                        } label: {
                            Image(systemName: "gear")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(.foregroundPrimary)
                                .frame(width: 30, height: 30)
                        }
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .background(Color.foregroundSecondary)
                        
                        Button {
                            showingKeySelection.toggle()
                        } label: {
                            HStack(spacing: 0.0) {
                                
                                Image(systemName: "key.fill")
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundColor(.foregroundSecondary)
                                    .frame(width: 30, height: 30)
                                
                                Text(currentKeyName)
                                
                                    .frame(alignment: .leading)
                                    .fontType(.small, on: .elevated)
                                Spacer().frame(width: 10)
                            }
                            
                        }
                        .frame(height: 44)
                        .background(Color.white)
                    }
                    .cornerRadius(cornerRadius)
                    
                    Spacer()
                        .frame(maxWidth: .infinity)
                    
                    Button(action: {
                        flashButtonPressed()
                    }, label: {
                        Image(systemName: flashMode.systemIconForMode)
                            .foregroundColor(flashMode.colorForMode)
                            .frame(width: 44, height: 44)
                    })
                    
                }
                .opacity(isRecordingVideo ? 0.0 : 1.0)
                .tint(.white)
                Text(recordingDuration.durationText)
                    .fontType(.small)
                    .padding(5)
                    .background(Color.videoRecordingIndicator)
                    .cornerRadius(10)
                    .opacity(isRecordingVideo ? 1.0 : 0.0)
            
        }.animation(.easeIn(duration: 0.1), value: isRecordingVideo)
    }
}

struct TopBarView_Previews: PreviewProvider {
    static var previews: some View {
        TopBarView(showingKeySelection: .constant(false), isRecordingVideo: .constant(false), recordingDuration: .constant(CMTime(seconds: 0, preferredTimescale: 1)), currentKeyName: .constant("A key"), flashMode: .constant(.off), settingsButtonTapped: {}, flashButtonPressed: {})
            .preferredColorScheme(.dark)
    }
}
