//
//  Log.swift
//  HopChat-1
//
//  Design Contract §6. Unified logging. Phone numbers, IP addresses and
//  message content are always logged with `privacy: .private` — never `print`.
//

import Foundation
import os

nonisolated enum Log {

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.hoppin"

    static let net    = Logger(subsystem: subsystem, category: "net")
    static let crypto = Logger(subsystem: subsystem, category: "crypto")
    static let store  = Logger(subsystem: subsystem, category: "store")
    static let ui     = Logger(subsystem: subsystem, category: "ui")
    static let app    = Logger(subsystem: subsystem, category: "app")
}
