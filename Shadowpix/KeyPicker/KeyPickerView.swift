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
    
    
    @State var isShowingSheetForKeyEntry: Bool = false
    @State var isShowingSheetForNewKey: Bool = false
    @Binding var isShown: Bool
    @EnvironmentObject var appState: ShadowPixState
    
   
    
    private struct Constants {
        static var outerPadding = 20.0
    }
    
    var body: some View {
        NavigationView {
            VStack {
                Text(appState.selectedKey?.name ?? "no key")
                    .padding()
                HStack {
                    Button("Set key") {
                        isShowingSheetForKeyEntry = true
                    }

                Button("Generate new key") {
                    isShowingSheetForNewKey = true
                }.foregroundColor(.blue)
                    Button("Copy to clipboard") {
                        UIPasteboard.general.string = appState.selectedKey?.base64String
                    }.foregroundColor(.blue)
                }
                Spacer()
            }.padding(Constants.outerPadding)
                .navigationTitle("Key Selection")
            
        }.sheet(isPresented: $isShowingSheetForNewKey) {
            
        } content: {
            KeyGeneration(isShown: $isShowingSheetForNewKey).environmentObject(appState)
        }.sheet(isPresented: $isShowingSheetForKeyEntry) {
            isShown = false
        } content: {
            KeyEntry(isShowing: $isShowingSheetForKeyEntry)
        }.foregroundColor(.blue)
            .onAppear {
            appState.selectedKey = WorkWithKeychain.getKeyObject()
        }


    }
}

struct KeyPickerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            KeyPickerView(isShowingSheetForNewKey: false, isShown: .constant(true))
                .environmentObject(ShadowPixState())
        }.preferredColorScheme(.dark)
//        NavigationView {
//            KeyPickerView(isShowingSheetForNewKey: false, isShown: .constant(true))
//        }.preferredColorScheme(.light)
    }
}
