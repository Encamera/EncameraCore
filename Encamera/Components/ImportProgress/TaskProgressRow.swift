//
//  TaskProgressRow.swift
//  Encamera
//
//  Created by Alexander Freas on 24.07.25.
//



import SwiftUI
import EncameraCore
import Combine
import Photos

struct TaskProgressRow: View {
    let task: ImportTask
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    
    var body: some View {
        HStack(spacing: 12) {
            // State indicator
            stateIcon
            
            // Progress info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(task.progress.currentFileIndex + 1) of \(task.progress.totalFiles) files")
                        .fontType(.pt12, weight: .medium)
                        .foregroundColor(.foregroundPrimary)
                    
                    Spacer()
                    
                    Text("\(Int(task.progress.overallProgress * 100))%")
                        .fontType(.pt12, weight: .medium)
                        .foregroundColor(.actionYellowGreen
)
                }

                ProgressView(value: task.progress.overallProgress, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: progressColor))
                    .frame(height: 3)
                
                if let fileName = task.progress.currentFileName {
                    Text("Processing: \(fileName)")
                        .fontType(.pt10)
                        .foregroundColor(.actionYellowGreen
)
                        .lineLimit(1)
                }


            }
            
            // Control buttons
            HStack(spacing: 8) {
                switch task.state {
                case .running:
                    Button(action: {
                        importManager.pauseImport(taskId: task.id)
                    }) {
                        Image(systemName: "pause.circle.fill")
                            .foregroundColor(.actionYellowGreen)
                            .font(.system(size: 18))
                    }
                    
                case .paused:
                    Button(action: {
                        Task {
                            try? await importManager.resumeImport(taskId: task.id)
                        }
                    }) {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.actionYellowGreen)
                            .font(.system(size: 18))
                    }
                    
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.actionYellowGreen)
                        .font(.system(size: 18))
                    
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 18))
                    
                default:
                    EmptyView()
                }
                
                Button(action: {
                    importManager.cancelImport(taskId: task.id)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.actionYellowGreen)
                        .font(.system(size: 16))
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.inputFieldBackgroundColor)
        .cornerRadius(8)
    }

    
    private var stateIcon: some View {
        Group {
            switch task.state {
            case .running:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .actionYellowGreen))
                    .scaleEffect(0.8)
            case .paused:
                Image(systemName: "pause.circle")
                    .foregroundColor(.orange)
                    .font(.system(size: 20))
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 20))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 20))
            case .cancelled:
                Image(systemName: "xmark.circle")
                    .foregroundColor(.actionYellowGreen
)
                    .font(.system(size: 20))
            case .idle:
                Image(systemName: "clock")
                    .foregroundColor(.actionYellowGreen
)
                    .font(.system(size: 20))
            }
        }
        .frame(width: 24, height: 24)
    }
    
    private var progressColor: Color {
        switch task.state {
        case .running:
            return .actionYellowGreen
        case .paused:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        default:
            return .actionYellowGreen

        }
    }
}
