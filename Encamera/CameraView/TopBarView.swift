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
import Combine

class TopBarViewViewModel: ObservableObject {
    
    var purchaseManager: PurchasedPermissionManaging
    private var cancellables = Set<AnyCancellable>()
    @Published var currentTutorialPillState: TopBarTutorialPillState = .notShown

    init(purchaseManager: PurchasedPermissionManaging) {
        self.purchaseManager = purchaseManager
        
    }
    
    
    
    @MainActor
    func setupObservers() async {
            
            let purchasedProductsPublisher = StoreActor.shared
                .productController
                .$purchasedProducts
                .map { $0 as Any? }
                .eraseToAnyPublisher()
                
            
            let purchasedSubscriptionPublisher = StoreActor.shared
                .subscriptionController
                .$entitledSubscriptionID
                .map { $0 as Any? }
                .eraseToAnyPublisher()


            Publishers.Merge4(
                UserDefaultUtils.publisher(for: .capturedPhotos) as AnyPublisher<Any?, Never>,
                UserDefaultUtils.publisher(for: .hasOpenedKeySelection) as AnyPublisher<Any?, Never>,
                purchasedProductsPublisher,
                purchasedSubscriptionPublisher)

            .receive(on: RunLoop.main)
            .sink { _ in
                self.determinePillState()
            }.store(in: &cancellables)
    }
    
    func determinePillState() {
        let capturedPhotos = UserDefaultUtils.integer(forKey: .capturedPhotos)
        let hasOpenedKeys = UserDefaultUtils.bool(forKey: .hasOpenedKeySelection)
        let hasPhotoAccess = purchaseManager.isAllowedAccess(feature: .accessPhoto(count: Double(capturedPhotos)))
        
        var retVal: TopBarTutorialPillState
        switch (capturedPhotos, hasPhotoAccess, hasOpenedKeys) {
        case (0, true, false):
            retVal = .noPhotosTaken
        case (_, true, false):
            retVal = .showTapOnKey

        case (let count, true, _) where Double(count) < AppConstants.maxPhotoCountBeforePurchase:
            let leftCount = max(0, Int(AppConstants.maxPhotoCountBeforePurchase) - capturedPhotos)
            retVal = .numberOfPhotosLeft(photoCount: leftCount)
        
        case (_, false, _):
            retVal = .noPhotosLeft
        default:
            retVal = .notShown
        }
        currentTutorialPillState = retVal
    }
    
    
    
}

struct TopBarView: View {
    
    @StateObject var viewModel: TopBarViewViewModel
    @Binding var showingKeySelection: Bool
    @Binding var showStoreSheet: Bool

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
                Spacer().frame(width: 10.0)
                settingsAndKeyButton
                Spacer()
                tutorialPill
                Spacer()
                flashButton
                
                
            }
            .opacity(isRecordingVideo ? 0.0 : 1.0)
            .tint(.white)
            
            durationText
        }
        .task {
            await viewModel.setupObservers()
            viewModel.determinePillState()
        }
        .animation(.easeIn(duration: 0.1), value: isRecordingVideo)
    }
    
    
    
    private var tutorialPill: some View {
        
        TopBarTutorialPill(currentState: $viewModel.currentTutorialPillState, showStoreSheet: $showStoreSheet)
            .onTapGesture {
                switch viewModel.currentTutorialPillState {
                case .numberOfPhotosLeft(_), .noPhotosLeft:
                    showStoreSheet = true
                default:
                    break
                }
            }
        
    }
    private var settingsAndKeyButton: some View {
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(alignment: .leading)
                        .fontType(.small, on: .elevated)
                    Spacer().frame(width: 10)
                }
                
            }
            .frame(height: 44)
            .background(Color.white)
        }
        .cornerRadius(cornerRadius)
    }
    
    private var flashButton: some View {
        Button(action: {
            flashButtonPressed()
        }, label: {
            Image(systemName: flashMode.systemIconForMode)
                .foregroundColor(flashMode.colorForMode)
                .frame(width: 44, height: 44)
        })
    }
    private var durationText: some View {
        Text(recordingDuration.durationText)
            .fontType(.small)
            .padding(5)
            .background(Color.videoRecordingIndicator)
            .cornerRadius(10)
            .opacity(isRecordingVideo ? 1.0 : 0.0)

    }
}

//struct TopBarView_Previews: PreviewProvider {
//    static var previews: some View {
//        TopBarView(viewModel: .init(purchaseManager: DemoPurchasedPermissionManaging()), showingKeySelection: .constant(false), isRecordingVideo: .constant(false), recordingDuration: .constant(CMTime(seconds: 0, preferredTimescale: 1)), currentKeyName: .constant("DefaultKey"), flashMode: .constant(.off), settingsButtonTapped: {}, flashButtonPressed: {})
//            .preferredColorScheme(.dark)
//    }
//}
