//
//  SafeAreaUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 17.10.23.
//

import Foundation
import UIKit

private var getKeyWindow: UIWindow? {
    return UIApplication.shared.connectedScenes
        .map({$0 as? UIWindowScene})
        .compactMap({$0})
        .first?.windows
        .filter({$0.isKeyWindow}).first
}

func getSafeAreaTop() -> CGFloat{

    return (getKeyWindow?.safeAreaInsets.top) ?? 0
    
}

func getSafeAreaBottom() -> CGFloat{

    let retVal = (getKeyWindow?.safeAreaInsets.bottom) ?? 0

    return retVal

}
