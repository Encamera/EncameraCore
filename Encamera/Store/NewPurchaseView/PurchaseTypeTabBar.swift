//
//  PurchaseTypeTabBar.swift
//  Encamera
//
//  Created by Alexander Freas on 09.10.25.
//

import SwiftUI

struct PurchaseTypeTabBar: View {
    @Binding var selectedType: PurchaseType
    let onSelectionChange: (PurchaseType) -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(PurchaseType.allCases, id: \.self) { type in
                tabButton(for: type)
            }
        }
    }
    
    private func tabButton(for type: PurchaseType) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                selectedType = type
                onSelectionChange(type)
            }
        } label: {
            VStack(spacing: 8) {
                Text(type.rawValue)
                    .fontType(.pt16, weight: selectedType == type ? .bold : .regular)
                    .foregroundColor(selectedType == type ? .white : .white.opacity(0.6))
                
                // Underline indicator
                Rectangle()
                    .fill(selectedType == type ? Color.white : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ZStack {
        Color.black
            .ignoresSafeArea()
        
        VStack {
            PurchaseTypeTabBar(
                selectedType: .constant(.subscriptions),
                onSelectionChange: { _ in }
            )
            .padding()
        }
    }
}


