//
//  URLTypes.swift
//  Encamera
//
//  Created by Alexander Freas on 08.09.22.
//

import Foundation

enum URLType: Equatable {
    
    private static var keyDataQueryParam = "data"
    
    case media(encryptedMedia: EncryptedMedia)
    case key(key: PrivateKey)
    
    init?(url: URL) {
        if let key = URLType.extractKey(url: url) {
            self = .key(key: key)
        } else if let media = URLType.extractMediaSource(url: url) {
            self = .media(encryptedMedia: media)
        } else {
            return nil
        }
    }
    
    var url: URL? {
        switch self {
        case .media(let encryptedMedia):
            return encryptedMedia.source
        case .key(let key):
            return keyURL(key: key)
        }
    }
    
    private func keyURL(key: PrivateKey) -> URL? {
        guard let keyString = key.base64String else {
            return nil
        }
        var components = URLComponents()
        components.scheme = AppConstants.deeplinkSchema
        components.host = "key"
        components.queryItems = [URLQueryItem(name: URLType.keyDataQueryParam, value: keyString)]
        
        
        return components.url
    }
    
    
    private static func extractKey(url: URL) -> PrivateKey? {
        guard url.absoluteString.starts(with: "\(AppConstants.deeplinkSchema)") else {
            return nil
        }
        
        let urlParams = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let keyParam = urlParams?.queryItems?.first(where: {$0.name == URLType.keyDataQueryParam})?.value,
              let extractedKey = try? PrivateKey(base64String: keyParam)
            else {
            return nil
        }
        
        return extractedKey
        
    }
    
    private static func extractMediaSource(url: URL) -> EncryptedMedia? {
        guard url.pathExtension == MediaType.photo.fileExtension else {
            return nil
        }
        return EncryptedMedia(source: url)
    }
    
}
