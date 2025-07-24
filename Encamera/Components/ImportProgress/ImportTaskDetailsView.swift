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
            .navigationTitle("Import Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear All") {
                        importManager.removeCompletedTasks()
                    }
                    .disabled(importManager.currentTasks.isEmpty)
                }
            }
        }
    }
}