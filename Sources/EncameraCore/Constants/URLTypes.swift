//
//  URLTypes.swift
//  Encamera
//
//  Created by Alexander Freas on 08.09.22.
//

import Foundation

public enum URLType: Equatable {
    
    private static var featureToggleQueryParam = "feature"
    
    case media(encryptedMedia: EncryptedMedia)
    case featureToggle(feature: Feature)
    case cameraFromWidget
    case pendingImport  // Deep link from Share Extension to trigger import flow

    public init?(url: URL) {
        if let media = URLType.extractMediaSource(url: url) {
            self = .media(encryptedMedia: media)
        } else if let feature = URLType.extractFeatureToggle(url: url) {
            self = .featureToggle(feature: feature)
        } else if url.absoluteString.starts(with: "\(AppConstants.deeplinkSchema)://camera") {
            self = .cameraFromWidget
        } else if url.absoluteString.starts(with: "\(AppConstants.deeplinkSchema)://pendingImport") {
            self = .pendingImport
        } else {
            return nil
        }
    }
    
    public var url: URL? {
        switch self {
        case .media(let encryptedMedia):
            guard case .url(let source) = encryptedMedia.source else {
                return nil
            }
            return source
        case .featureToggle(feature: let feature):
            return featureToggleURL(feature: feature)
        case .cameraFromWidget:
            return cameraURL()
        case .pendingImport:
            return pendingImportURL()
        }
    }
    
    private func pendingImportURL() -> URL? {
        var components = URLComponents()
        components.scheme = AppConstants.deeplinkSchema
        components.host = "pendingImport"
        return components.url
    }

    private func cameraURL() -> URL? {
        var components = URLComponents()
        components.scheme = AppConstants.deeplinkSchema
        components.host = "camera"
        return components.url
    }

    private func featureToggleURL(feature: Feature) -> URL? {
        var components = URLComponents()
        components.scheme = AppConstants.deeplinkSchema
        components.host = "featureToggle"
        components.queryItems = [URLQueryItem(name: URLType.featureToggleQueryParam, value: feature.rawValue)]
        return components.url
    }
    
    private static func extractMediaSource(url: URL) -> EncryptedMedia? {
        guard url.pathExtension == MediaType.photo.encryptedFileExtension || url.pathExtension == MediaType.video.encryptedFileExtension else {
            return nil
        }
        return EncryptedMedia(source: url)
    }
    
    private static func extractFeatureToggle(url: URL) -> Feature? {
        let urlParams = URLComponents(url: url, resolvingAgainstBaseURL: false)

        guard let featureParam = urlParams?.queryItems?.first(where: {$0.name == URLType.featureToggleQueryParam})?.value else {
            return nil
        }
            return Feature(rawValue: featureParam)
    }
    
}
