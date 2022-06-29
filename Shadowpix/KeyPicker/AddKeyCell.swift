//
//  AddKeyCell.swift
//  Shadowpix
//
//  Created by Alexander Freas on 24.06.22.
//

import SwiftUI

struct AddKeyCell: View {
    
    var title: String
    
    var body: some View {
        HStack {
            Text(title).font(.title)
            Spacer()
        }.padding()
    }
}

struct AddKeyCell_Previews: PreviewProvider {
    static var previews: some View {
        AddKeyCell(title: "Add Key")
    }
}
