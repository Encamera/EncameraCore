//
//  TopBarTutorialPill.swift
//  Encamera
//
//  Created by Alexander Freas on 28.04.23.
//

import Foundation
import SwiftUI
import EncameraCore

enum TopBarTutorialPillState {
    case noPhotosTaken
    case showTapOnKey
    case numberOfPhotosLeft(photoCount: Int)
    case noPhotosLeft
    case notShown
}

struct TopBarTutorialPill: View {
    
    @Binding var currentState: TopBarTutorialPillState
    @State var shift: Double = 0.0
    @State var scaleAnimation: Double = 1.0
    @Binding var showStoreSheet: Bool
    var body: some View {
        
        Group {
            let state = currentState
            switch state {
            case .noPhotosTaken:
                stateForNoPhotosTaken
            case .showTapOnKey:
                stateForTapOnKey
            case .numberOfPhotosLeft(let photos):
                stateForNumberOfPhotosLeft(photosLeft: photos)
            case .notShown:
                notShown
            case .noPhotosLeft:
                noPhotosLeft
            }
        }
    
        
    }
    
    
    
    
    @State private var photosLeft = 10
    @State private var displayPhotosLeft = true
    @State private var opacity: Double = 1.0

    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private func stateForNumberOfPhotosLeft(photosLeft: Int) -> some View {
        Text(displayPhotosLeft ? "\(photosLeft) \(L10n.photoSLeft(photosLeft))" : L10n.tapToUpgrade)
                    .textPill(color: .warningColor)
                    .fontType(.pt18, on: .elevated)
                    .opacity(opacity)
                    .onReceive(timer) { _ in
                        withAnimation(.easeInOut(duration: 1)) {
                            opacity = 0.0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            withAnimation(.easeInOut(duration: 1)) {
                                opacity = 1.0
                            }
                            displayPhotosLeft.toggle()
                        }
                    }
    }
    
    private var stateForTapOnKey: some View {
        Text("\(Image(systemName: "arrow.backward")) \(L10n.yourKeys)")
            .textPill(color: .actionButton)
            .offset(x: shift)
            .onAppear {
                withAnimation(Animation.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    shift = 10
                }
            }
    }
    
    private var stateForNoPhotosTaken: some View {
            Text("\(Image(systemName: "circle.circle")) \(L10n.takeAPhoto)")
            
            .textPill(color: .actionButton)
            .scaleEffect(scaleAnimation)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1)
                    .repeatForever(autoreverses: true)
                ) {
                    scaleAnimation = 1.1
                }
            }
    }
    
    private var noPhotosLeft: some View {
        Text("\(L10n.tapToUpgrade)")
        .textPill(color: .green)
        .foregroundColor(.background)
    }
    
    private var notShown: some View {
        return EmptyView()
    }
    
}

struct TopBarTutorialPill_Previews: PreviewProvider {
    
    static var previews: some View {
        
        VStack {
            TopBarTutorialPill(currentState: .constant(.noPhotosTaken), showStoreSheet: .constant(false))
            TopBarTutorialPill(currentState: .constant(.numberOfPhotosLeft(photoCount: 3)), showStoreSheet: .constant(false))
            TopBarTutorialPill(currentState: .constant(.showTapOnKey), showStoreSheet: .constant(false))
            TopBarTutorialPill(currentState: .constant(.notShown), showStoreSheet: .constant(false))
            TopBarTutorialPill(currentState: .constant(.noPhotosLeft), showStoreSheet: .constant(false))
        }
            .preferredColorScheme(.dark)
    }
    
}
