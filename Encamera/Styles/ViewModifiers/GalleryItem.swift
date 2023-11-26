//
//  GalleryItem.swift
//  Encamera
//
//  Created by Alexander Freas on 26.10.23.
//

import Foundation
import SwiftUI

extension View {

    @ViewBuilder
    func galleryClipped() -> some View {
        self.clipShape(RoundedRectangle(cornerRadius: 10, style: .circular))
    }
}
