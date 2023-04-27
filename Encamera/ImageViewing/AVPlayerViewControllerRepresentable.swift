//
//  AVPlayerView.swift
//  Encamera
//
//  Created by Alexander Freas on 27.04.23.
//

import Foundation
import SwiftUI
import AVKit

struct AVPlayerViewRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer?
    
    init(player: AVPlayer?) {
        self.player = player
    }
    
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        
        let playerViewController = AVPlayerViewController()
        return playerViewController
    }
    
    func updateUIViewController(_ playerViewController: AVPlayerViewController, context: Context) {
        playerViewController.player = player
        
        playerViewController.updatesNowPlayingInfoCenter = false
        playerViewController.entersFullScreenWhenPlaybackBegins = true
        playerViewController.showsPlaybackControls = false
    }
    
}

