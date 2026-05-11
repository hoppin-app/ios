//
//  Config.swift
//  HopChat-1
//

import Foundation

enum AppConfig {
    static var bootstrapIP: String {
        let saved = UserDefaults.standard.string(forKey: "hopchat.bootstrap.ip") ?? ""
        return saved.isEmpty ? "34.14.80.215" : saved
    }

    static var bootstrapPort: UInt16 {
        let saved = UserDefaults.standard.integer(forKey: "hopchat.bootstrap.port")
        return saved > 0 ? UInt16(saved) : 4001
    }

    /// DHT value TTL in seconds (30 minutes).
    static let dhtTTL: TimeInterval = 30 * 60
}
