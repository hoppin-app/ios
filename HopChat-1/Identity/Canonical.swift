//
//  Canonical.swift
//  HopChat-1
//
//  Canonical signing encoding — Design Contract §1.
//  Byte-exact counterpart of the Python `canonical(fields)` helper.
//

import Foundation

/// Length-prefixed field-list encoding used for every signature and for AEAD
/// associated data.
///
/// `Canonical(fields) = concat over f in fields of: ASCII(decimal(utf8_byte_len(f))) + ":" + UTF8(f)`
///
/// Example: `["ab", "", "é"]` → `2:ab0:2:é`
nonisolated enum Canonical {

    /// Encodes a field list into its canonical byte representation.
    static func encode(_ fields: [String]) -> Data {
        var out = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            out.append(contentsOf: Array(String(bytes.count).utf8))
            out.append(0x3A) // ":"
            out.append(bytes)
        }
        return out
    }

    // MARK: - Field helpers (contract §1: integers base-10 no leading zeros, bools "1"/"0", nil → "")

    /// Renders an integer as a canonical field (base 10, no leading zeros).
    static func field(_ value: Int64) -> String { String(value) }

    /// Renders an integer as a canonical field (base 10, no leading zeros).
    static func field(_ value: Int) -> String { String(value) }

    /// Renders an unsigned integer as a canonical field.
    static func field(_ value: UInt16) -> String { String(value) }

    /// Renders a boolean as a canonical field (`"1"` / `"0"`).
    static func field(_ value: Bool) -> String { value ? "1" : "0" }

    /// Renders an optional string as a canonical field (`nil` → `""`).
    static func field(_ value: String?) -> String { value ?? "" }
}
