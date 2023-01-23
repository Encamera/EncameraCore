//
//  AddKeyCell.swift
//  Encamera
//
//  Created by Alexander Freas on 24.06.22.
//

import SwiftUI

struct KeyOperationCell: View {
    
    var title: String
    var imageName: String
    
    var body: some View {
        HStack {
            Image(systemName: imageName)
            Text(title)
                .fontType(.medium)
            Spacer()
        }
        .fontType(.small)
        .padding()
    }
}

struct AddKeyCell_Previews: PreviewProvider {
    static var previews: some View {
        KeyOperationCell(title: "Add Key", imageName: "doc.on.doc.fill")
    }
}
