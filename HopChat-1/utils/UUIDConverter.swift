//
//  UUIDConverter.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 26/02/2026.
//
import Foundation
import CryptoKit

extension UUID {
    static func v5(namespace: UUID = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!, name: String) -> UUID {
        var hasher = Insecure.SHA1()
        
        // FIXED: UUID to Data
        hasher.update(data: namespace.uuidString.data(using: .utf8)!)
        hasher.update(data: Data(name.utf8))
        
        let digest = hasher.finalize()
        var uuidBytes = Array(digest.prefix(16))
        
        // Version 5 + variant
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        
        return UUID(uuid: uuidBytes.withUnsafeBytes {
            $0.load(as: uuid_t.self)
        })
    }
}


