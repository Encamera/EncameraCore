//
//  HardwareVolumeButtonCaptureUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 08.05.23.
//

import Foundation
import AVKit
import Combine
import MediaPlayer
import EncameraCore
class HardwareVolumeButtonCaptureUtils: NSObject {
    
    let audioSession = AVAudioSession()
    static var shared = HardwareVolumeButtonCaptureUtils()
    private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: -100, width: 0, height: 0)) // override volume view

    var captureButtonPublisher: AnyPublisher<Bool, Never> {
        captureButtonSubject.eraseToAnyPublisher()
    }
    
    private var captureButtonSubject: PassthroughSubject<Bool, Never>
    
    override init() {
        captureButtonSubject = PassthroughSubject()
    }
    
    func setupVolumeView() {
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let view = windowScene.windows.first?.rootViewController?.view else {
            print("Could not get view")
            return
        }
        if volumeView.superview == nil {
            view.addSubview(volumeView)
        }
    }
    
    
    
    func startObservingCaptureButton() {
        
        try? self.audioSession.setActive(true)
        self.audioSession.addObserver(self, forKeyPath: "outputVolume", options: NSKeyValueObservingOptions.new, context: nil)
        debugPrint("HardwareVolumeButtonCaptureUtils.startObservingCaptureButton")

    }
    
    func stopObservingCaptureButton() {
        
        try? self.audioSession.setActive(false)

        self.audioSession.removeObserver(self, forKeyPath: "outputVolume")
        debugPrint("HardwareVolumeButtonCaptureUtils.stopObservingCaptureButton")
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        NotificationUtils.sendHardwareButtonPressed()
        if let newValue = change?[NSKeyValueChangeKey.newKey] as? Int, keyPath == "outputVolume" && (newValue == 1 || newValue == 0) {
            if newValue == 1 {
                setVolume(0.9)
            } else {
                setVolume(0.1)
            }
        }
    }
    
    private func setVolume(_ volume: Float, completion: (() -> Void)? = nil) {
        let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
            slider?.value = volume

            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.01) {
                // needed to wait a bit before completing so the observer doesn't pick up the manualq volume change
                completion?()
            }
        }
    }
}
