//
//  ExtendedAttributesUtil.swift
//  EncameraCore
//
//  Created by Alexander Freas on [Date].
//

import Foundation

public enum ExtendedAttributesError: Error {
    case attributeNotFound
    case invalidData
    case setAttributeFailed
    case getAttributeFailed
}

public struct ExtendedAttributesUtil {
    
    private static let keyUUIDAttribute = "com.encamera.keyUUID"
    
    /// Sets the key UUID as an extended attribute on the file
    public static func setKeyUUID(_ uuid: UUID, for url: URL) throws {
        let uuidData = uuid.data
        let result = uuidData.withUnsafeBytes { bytes in
            setxattr(url.path, keyUUIDAttribute, bytes.bindMemory(to: UInt8.self).baseAddress, uuidData.count, 0, 0)
        }
        
        if result != 0 {
            throw ExtendedAttributesError.setAttributeFailed
        }
    }
    
    /// Gets the key UUID from the extended attributes of the file
    public static func getKeyUUID(for url: URL) throws -> UUID? {
        // First, get the size of the attribute
        let size = getxattr(url.path, keyUUIDAttribute, nil, 0, 0, 0)
        
        if size < 0 {
            let error = errno
            if error == ENOATTR {
                // Attribute doesn't exist - this is normal for files encrypted before this feature
                return nil
            } else {
                throw ExtendedAttributesError.getAttributeFailed
            }
        }
        
        // UUID should be exactly 16 bytes
        guard size == 16 else {
            throw ExtendedAttributesError.invalidData
        }
        
        // Read the attribute data
        var buffer = Data(count: Int(size))
        let result = buffer.withUnsafeMutableBytes { bytes in
            getxattr(url.path, keyUUIDAttribute, bytes.bindMemory(to: UInt8.self).baseAddress, size, 0, 0)
        }
        
        if result != size {
            throw ExtendedAttributesError.getAttributeFailed
        }
        
        // Convert data back to UUID
        return buffer.withUnsafeBytes { bytes in
            let uuidBytes = bytes.bindMemory(to: uuid_t.self).baseAddress!.pointee
            return UUID(uuid: uuidBytes)
        }
    }
    
    /// Removes the key UUID extended attribute from the file
    public static func removeKeyUUID(for url: URL) throws {
        let result = removexattr(url.path, keyUUIDAttribute, 0)
        if result != 0 && errno != ENOATTR {
            throw ExtendedAttributesError.getAttributeFailed
        }
    }
} 