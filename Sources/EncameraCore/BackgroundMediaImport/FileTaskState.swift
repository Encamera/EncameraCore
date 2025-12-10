//
//  FileTaskState.swift
//  EncameraCore
//
//  Created by Alexander Freas on 24.07.25.
//



public enum FileTaskState: Equatable {
    case idle
    case running
    case paused
    case completed
    case cancelled
    case failed(Error)
    
    public static func == (lhs: FileTaskState, rhs: FileTaskState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.running, .running),
             (.paused, .paused),
             (.completed, .completed),
             (.cancelled, .cancelled):
            return true
        case (.failed(let lError), .failed(let rError)):
            return lError.localizedDescription == rError.localizedDescription
        default:
            return false
        }
    }
}
