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
            layer.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
        }
    }
    
    let player: AVPlayer?
    
    init(player: AVPlayer?) {
        self.player = player
    }
    
    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView(player: self.player)
        return view
    }
    
    func updateUIView(_ view: PlayerUIView, context: Context) {
        
        //        let layer = AVPlayerLayer(player: self.player)
        //        layer.backgroundColor = UIColor.orange.cgColor
        //        layer.bounds = view.frame
        //        view.layer.insertSublayer(layer, at: 0)
        //        view.layer.layoutIfNeeded()
        //        view.layer.backgroundColor = UIColor.green.cgColor
    }
    
}

