//
//  ChunkedFiles.swift
//  Encamera
//
//  Created by Alexander Freas on 13.06.22.
//

import Foundation

struct ChunkedFilesProcessing<T: MediaDescribing> {
    let sourceFileHandle: FileLikeHandler<T>
    let blockSize: Int

    init(sourceFileHandle: FileLikeHandler<T>, blockSize: Int = Constants.defaultBlockSize) {
        self.sourceFileHandle = sourceFileHandle
        self.blockSize = blockSize
    }
    
    func handleFile() -> Data
}
