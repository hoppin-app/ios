//
//  KeychainHelper.swift
//  HopChat-1
//
//  Created by Rodrigo Loução on 26/02/2026.
//


import Security
import Foundation

class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "HopChat.NodeUUID" 
    
    func saveUUID(_ uuid: UUID, forKey key: String = "nodeUUID") -> Bool {
        guard let data = uuid.uuidString.data(using: .utf8) else { return false }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly  // Strongest protection
        ]
        
        // Delete existing
        SecItemDelete(query as CFDictionary)
        
        // Add new
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    func getUUID(forKey key: String = "nodeUUID") -> UUID? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let uuidString = String(data: data, encoding: .utf8),
              let uuid = UUID(uuidString: uuidString) else { return nil }
        
        return uuid
    }
}
