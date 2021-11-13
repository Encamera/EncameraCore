//
//  KeyPickerView.swift
//  shadowpix
//
//  Created by Alexander Freas on 09.11.21.
//

import SwiftUI

struct KeyPickerView: View {
    
//    class ViewModel: ObservableObject {
//        @Published var
//    }
    
    
    @State var isShowingAlertForNewKey: Bool = false
    @State var isShowingAlertForSaveKey: Bool = false
    
    @State var keyValue: String = {
        guard let key = WorkWithKeychain.getKey() else {
            return "Lro8pRFAL6w0WCQSu6H5fCZbO+3kaJlw2IPY7/G8m8k="
        }
        return String(data: key.base64EncodedData(), encoding: .utf8) ?? ""
    }()
    
    private struct Constants {
        static var outerPadding = 20.0
    }
    
    var body: some View {
        NavigationView {
        VStack {
//            Text("Invalid Key").foregroundColor(.red).onReceive(keyValue) { value in
//                
//            }
            TextEditor(text: $keyValue)
                .frame(maxHeight: 200)
            Button("Generate new key") {
                isShowingAlertForNewKey = true
            }.alert("Are you sure you want to generate a new key?", isPresented: $isShowingAlertForNewKey) {
                Button("Yes", role: .destructive) {
                    ChaChaPolyHelpers.generateNewKey()
                    keyValue = WorkWithKeychain.getKeyString() ?? ""
                }
                Button("Cancel", role: .cancel) {
                    isShowingAlertForNewKey = false
                }
            }.foregroundColor(.blue)
            Spacer()
        }.padding(Constants.outerPadding)
            .navigationTitle("Key Selection")
            .toolbar {
                Button("Save") {
                    isShowingAlertForSaveKey = true
                }.alert("Are you sure you want to save this key?", isPresented: $isShowingAlertForSaveKey) {
                    Button("Yes", role: .destructive) {
                        WorkWithKeychain.updateKey(key: keyValue)
                    }
                    Button("Cancel", role: .cancel) {
                        isShowingAlertForSaveKey = false
                    }
                }.foregroundColor(.blue)
            }
        }
    }
}

struct KeyPickerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            KeyPickerView(isShowingAlertForNewKey: false, isShowingAlertForSaveKey: false)
        }.preferredColorScheme(.dark)
        NavigationView {
            KeyPickerView(isShowingAlertForNewKey: false, isShowingAlertForSaveKey: false)
        }.preferredColorScheme(.light)
    }
}
