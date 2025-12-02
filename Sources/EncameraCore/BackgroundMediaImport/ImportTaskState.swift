//
//  ImportTaskState.swift
//  EncameraCore
//
//  Created by Alexander Freas on 24.07.25.
//



public enum ImportTaskState: Equatable {
    case idle
    case preparing(totalFiles: Int, preparedFiles: Int)  // New state for file preparation phase
    case running
    case paused
    case completed
    case cancelled
    case failed(Error)
    
    public static func == (lhs: ImportTaskState, rhs: ImportTaskState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.running, .running),
             (.paused, .paused),
             (.completed, .completed),
             (.cancelled, .cancelled):
            return true
        case (.preparing(let lTotal, let lPrepared), .preparing(let rTotal, let rPrepared)):
            return lTotal == rTotal && lPrepared == rPrepared
        case (.failed(let lError), .failed(let rError)):
            return lError.localizedDescription == rError.localizedDescription
        default:
            return false
        }
    }
}
