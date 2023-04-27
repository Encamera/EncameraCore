//
//  AVPlayerView.swift
//  Encamera
//
//  Created by Alexander Freas on 27.04.23.
//

import Foundation
import SwiftUI
import AVKit

struct AVPlayerLayerRepresentable: UIViewRepresentable {
    
    class PlayerUIView: UIView {
        private let playerLayer = AVPlayerLayer()
        
        var isExpanded: Bool = true {
            didSet {
                playerLayer.videoGravity = isExpanded ? .resizeAspectFill : .resizeAspect
            }
        }
        
        init(player: AVPlayer?) {
            super.init(frame: .zero)
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            clipsToBounds = true
            layer.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
            layer.masksToBounds = true
            playerLayer.masksToBounds = true
            print("bounds", layer.bounds, playerLayer.bounds, frame)
        }
    }
    
    let player: AVPlayer?
    let isExpanded: Bool
    
    init(player: AVPlayer?, isExpanded: Bool) {
        self.player = player
        self.isExpanded = isExpanded
        
    }
    
    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView(player: self.player)
        return view
    }
    
    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.isExpanded = self.isExpanded
    }
    
}

