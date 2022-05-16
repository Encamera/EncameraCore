//
//  ImageViewingUseCase.swift
//  Shadowpix
//
//  Created by Alexander Freas on 13.05.22.
//

import Foundation
import Combine

struct ImageViewingUseCase {
    

    
    func enumerateMediaType(type: MediaType, start: Int, count: Int) -> AnyPublisher<[ShadowPixMedia], Error> {
        
        
        
    }
    
    
}

class ImageEnumerationPublisher<S: Subscriber>: Subscription where S.Input ==
