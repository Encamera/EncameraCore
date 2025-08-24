//
//  ImportTaskDetailsView.swift
//  Encamera
//
//  Created by Alexander Freas on 24.07.25.
//



import SwiftUI
import EncameraCore
import Combine
import Photos

struct ImportTaskDetailsView: View {
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(importManager.currentTasks, id: \.id) { task in
                        TaskDetailCard(task: task)
                    }
                }
                .padding()
            }
            .navigationTitle(L10n.ImportTaskDetailsView.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.ImportTaskDetailsView.done) {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.ImportTaskDetailsView.clearAll) {
                        importManager.removeCompletedTasks()
                    }
                    .disabled(importManager.currentTasks.isEmpty)
                }
            }
        }
    }
}