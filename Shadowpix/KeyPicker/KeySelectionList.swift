//
//  KeySelectionList.swift
//  Shadowpix
//
//  Created by Alexander Freas on 22.06.22.
//

import SwiftUI

class KeySelectionListViewModel: ObservableObject {
    var keyManager: MultipleKeyKeychainManager
    
    init(keyManager: MultipleKeyKeychainManager) {
        self.keyManager = keyManager
    }
}

struct KeySelectionList: View {
    
    
    
    var body: some View {
        Text(/*@START_MENU_TOKEN@*/"Hello, World!"/*@END_MENU_TOKEN@*/)
    }
}

struct KeySelectionList_Previews: PreviewProvider {
    static var previews: some View {
        KeySelectionList()
    }
}
