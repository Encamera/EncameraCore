//
//  SafeAreaUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 17.10.23.
//

import Foundation
import UIKit

func getSafeAreaTop() -> CGFloat{

    let keyWindow = UIApplication.shared.connectedScenes
        .filter({$0.activationState == .foregroundActive})
        .map({$0 as? UIWindowScene})
        .compactMap({$0})
        .first?.windows
        .filter({$0.isKeyWindow}).first

    return (keyWindow?.safeAreaInsets.top) ?? 0

}

func getSafeAreaBottom() -> CGFloat{

    let keyWindow = UIApplication.shared.connectedScenes
        .map({$0 as? UIWindowScene})
        .compactMap({$0})
        .first?.windows
        .filter({$0.isKeyWindow}).first

    let retVal = (keyWindow?.safeAreaInsets.bottom) ?? 0

    return retVal

}
