//
//  PhoneNumber.swift
//  HopChat-1
//
//  E.164 normalization — Design Contract §2 ("Phone numbers").
//

import Foundation

nonisolated enum PhoneNumber {

    /// `^\+[1-9][0-9]{7,14}$`
    static func isValidE164(_ s: String) -> Bool {
        guard s.count >= 9, s.count <= 16 else { return false }
        var it = s.makeIterator()
        guard it.next() == "+" else { return false }
        guard let first = it.next(), first.isASCII, first.isNumber, first != "0" else { return false }
        var count = 0
        while let c = it.next() {
            guard c.isASCII, c.isNumber else { return false }
            count += 1
        }
        return count >= 7 && count <= 14
    }

    /// Normalizes user input to E.164, or returns nil if it cannot be made valid.
    ///
    /// - strips spaces (incl. non-breaking/thin), dashes (incl. en/em dash), dots, parentheses, slashes
    /// - leading `00` → `+`
    /// - no `+` → prepend the calling code of `defaultRegion`, dropping a single
    ///   national trunk `0` (kept for Italy, where the leading 0 is significant)
    /// Filters live text-field input down to what a typed phone number can
    /// contain: digits, a single leading "+", and common separators. Anything
    /// else (letters, "*", "#") is dropped as it is typed or pasted.
    static func sanitizeInput(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            if ch.isASCII, ch.isNumber {
                out.append(ch)
            } else if ch == "+", out.allSatisfy({ $0 == " " }) {
                out.append(ch)
            } else if " -().".contains(ch) {
                out.append(ch)
            }
        }
        return out
    }

    static func normalize(_ raw: String,
                          defaultRegion: String? = Locale.current.region?.identifier) -> String? {
        var s = ""
        for ch in raw {
            switch ch {
            case " ", "\u{00A0}", "\u{202F}", "\u{2009}", "\t", "\n", "\r",
                 "-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}",
                 ".", "(", ")", "[", "]", "/", "\\", "_":
                continue
            default:
                s.append(ch)
            }
        }
        guard !s.isEmpty else { return nil }

        // Common "+" spellings.
        if s.hasPrefix("\u{FF0B}") { s = "+" + s.dropFirst() }

        if s.hasPrefix("00") {
            s = "+" + s.dropFirst(2)
        }

        if !s.hasPrefix("+") {
            guard s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            guard let region = defaultRegion?.uppercased(),
                  let code = callingCode(forRegion: region) else { return nil }
            var national = s
            // Drop one national trunk prefix "0" (Italy keeps it).
            if region != "IT", national.hasPrefix("0") {
                national = String(national.dropFirst())
                s = "+" + code + national
            } else if national.hasPrefix(code), national.count - code.count >= 8 {
                // The country code typed without "+" ("351912345678"): prefixing
                // it again would produce "+351351912345678".
                s = "+" + national
            } else {
                s = "+" + code + national
            }
        }

        // Everything after "+" must be digits.
        let digits = s.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        let e164 = "+" + digits
        return isValidE164(e164) ? e164 : nil
    }

    /// Masks a phone number for logs / server output: keeps the first 6 characters
    /// and the last 2 digits, replacing the middle with `*`.
    /// `"+351912345678"` → `"+35191*****78"`.
    static func masked(_ e164: String) -> String {
        let chars = Array(e164)
        guard chars.count > 8 else { return e164 }
        let head = String(chars[0..<6])
        let tail = String(chars[(chars.count - 2)...])
        let stars = String(repeating: "*", count: chars.count - 8)
        return head + stars + tail
    }

    /// ITU calling code for an ISO-3166-1 alpha-2 region code.
    static func callingCode(forRegion region: String) -> String? {
        callingCodes[region.uppercased()]
    }

    // MARK: - ISO-3166-1 alpha-2 → ITU-T E.164 calling code

    static let callingCodes: [String: String] = [
        "AC": "247", "AD": "376", "AE": "971", "AF": "93",  "AG": "1",   "AI": "1",
        "AL": "355", "AM": "374", "AO": "244", "AQ": "672", "AR": "54",  "AS": "1",
        "AT": "43",  "AU": "61",  "AW": "297", "AX": "358", "AZ": "994",
        "BA": "387", "BB": "1",   "BD": "880", "BE": "32",  "BF": "226", "BG": "359",
        "BH": "973", "BI": "257", "BJ": "229", "BL": "590", "BM": "1",   "BN": "673",
        "BO": "591", "BQ": "599", "BR": "55",  "BS": "1",   "BT": "975", "BW": "267",
        "BY": "375", "BZ": "501",
        "CA": "1",   "CC": "61",  "CD": "243", "CF": "236", "CG": "242", "CH": "41",
        "CI": "225", "CK": "682", "CL": "56",  "CM": "237", "CN": "86",  "CO": "57",
        "CR": "506", "CU": "53",  "CV": "238", "CW": "599", "CX": "61",  "CY": "357",
        "CZ": "420",
        "DE": "49",  "DJ": "253", "DK": "45",  "DM": "1",   "DO": "1",   "DZ": "213",
        "EC": "593", "EE": "372", "EG": "20",  "EH": "212", "ER": "291", "ES": "34",
        "ET": "251",
        "FI": "358", "FJ": "679", "FK": "500", "FM": "691", "FO": "298", "FR": "33",
        "GA": "241", "GB": "44",  "GD": "1",   "GE": "995", "GF": "594", "GG": "44",
        "GH": "233", "GI": "350", "GL": "299", "GM": "220", "GN": "224", "GP": "590",
        "GQ": "240", "GR": "30",  "GT": "502", "GU": "1",   "GW": "245", "GY": "592",
        "HK": "852", "HN": "504", "HR": "385", "HT": "509", "HU": "36",
        "ID": "62",  "IE": "353", "IL": "972", "IM": "44",  "IN": "91",  "IO": "246",
        "IQ": "964", "IR": "98",  "IS": "354", "IT": "39",
        "JE": "44",  "JM": "1",   "JO": "962", "JP": "81",
        "KE": "254", "KG": "996", "KH": "855", "KI": "686", "KM": "269", "KN": "1",
        "KP": "850", "KR": "82",  "KW": "965", "KY": "1",   "KZ": "7",
        "LA": "856", "LB": "961", "LC": "1",   "LI": "423", "LK": "94",  "LR": "231",
        "LS": "266", "LT": "370", "LU": "352", "LV": "371", "LY": "218",
        "MA": "212", "MC": "377", "MD": "373", "ME": "382", "MF": "590", "MG": "261",
        "MH": "692", "MK": "389", "ML": "223", "MM": "95",  "MN": "976", "MO": "853",
        "MP": "1",   "MQ": "596", "MR": "222", "MS": "1",   "MT": "356", "MU": "230",
        "MV": "960", "MW": "265", "MX": "52",  "MY": "60",  "MZ": "258",
        "NA": "264", "NC": "687", "NE": "227", "NF": "672", "NG": "234", "NI": "505",
        "NL": "31",  "NO": "47",  "NP": "977", "NR": "674", "NU": "683", "NZ": "64",
        "OM": "968",
        "PA": "507", "PE": "51",  "PF": "689", "PG": "675", "PH": "63",  "PK": "92",
        "PL": "48",  "PM": "508", "PR": "1",   "PS": "970", "PT": "351", "PW": "680",
        "PY": "595",
        "QA": "974",
        "RE": "262", "RO": "40",  "RS": "381", "RU": "7",   "RW": "250",
        "SA": "966", "SB": "677", "SC": "248", "SD": "249", "SE": "46",  "SG": "65",
        "SH": "290", "SI": "386", "SJ": "47",  "SK": "421", "SL": "232", "SM": "378",
        "SN": "221", "SO": "252", "SR": "597", "SS": "211", "ST": "239", "SV": "503",
        "SX": "1",   "SY": "963", "SZ": "268",
        "TA": "290", "TC": "1",   "TD": "235", "TG": "228", "TH": "66",  "TJ": "992",
        "TK": "690", "TL": "670", "TM": "993", "TN": "216", "TO": "676", "TR": "90",
        "TT": "1",   "TV": "688", "TW": "886", "TZ": "255",
        "UA": "380", "UG": "256", "US": "1",   "UY": "598", "UZ": "998",
        "VA": "39",  "VC": "1",   "VE": "58",  "VG": "1",   "VI": "1",   "VN": "84",
        "VU": "678",
        "WF": "681", "WS": "685",
        "XK": "383",
        "YE": "967", "YT": "262",
        "ZA": "27",  "ZM": "260", "ZW": "263"
    ]
}
