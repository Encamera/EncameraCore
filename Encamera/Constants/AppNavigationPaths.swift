//
//  Navigation.swift
//  Encamera
//
//  Created by Alexander Freas on 15.09.24.
//

import Foundation
import EncameraCore


enum AppNavigationPaths: Hashable {


    case createAlbum
    case albumDetail(album: Album)
    
    // Settings navigation paths
    case authenticationMethod
    case backupKeyPhrase
    case importKeyPhrase
    case openSource
    case privacyPolicy
    case termsOfUse
    case eraseAllData
    case eraseAppData
    case roadmap
}



