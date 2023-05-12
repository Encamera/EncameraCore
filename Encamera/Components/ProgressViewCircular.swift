//
//  ProgressViewCircular.swift
//  Encamera
//
//  Created by Alexander Freas on 07.11.22.
//

import SwiftUI

struct ProgressViewCircular: View {
    
    var progress: Int
    var total: Int
    
    var body: some View {
        ZStack {
            ProgressView(value: Float(progress), total: Float(total))
                .progressViewStyle(ProgressViewCircularStyle())
            Text("\( progress)")
                .fontType(.small)
        }
    }
}

struct ProgressViewCircularStyle: ProgressViewStyle {
    
    func makeBody(configuration: Configuration) -> some View {
        let edge = 60.0
        
        let inner = edge * 0.7
        Circle()
            .scale(anchor: .topLeading)
            .trim(from: 0.0, to: configuration.fractionCompleted ?? 1.0)
            .rotation(.degrees(90))
            .stroke(
                Color.foregroundPrimary,
                lineWidth: 4
            )
            .frame(width: inner, height: inner)
    }
}


struct ProgressViewCircular_Previews: PreviewProvider {
    static var previews: some View {
        
        ProgressViewCircular(progress: 20, total: 100)
    }
}


