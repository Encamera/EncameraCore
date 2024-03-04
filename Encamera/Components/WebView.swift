//
//  WebView.swift
//  Encamera
//
//  Created by Alexander Freas on 26.10.23.
//

import Foundation
import SwiftUI
import WebKit


struct WebView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> WKWebView {
        return WKWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url = url {
            uiView.load(URLRequest(url: url))
        }
    }
}
