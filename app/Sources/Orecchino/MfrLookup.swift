import Foundation

/// Decodes the ANSI/CTA-2063-A manufacturer code (first 4 characters of a
/// Remote ID serial number). The CTA's code registry is not public, so this
/// table holds only codes verified against manufacturer documentation —
/// extend it as codes are confirmed. Owner/registration lookup is not
/// possible by design: FAA registration data is private and the UAS DOC
/// portal has no public API.
enum MfrLookup {
    private static let codes: [String: String] = [
        "1581": "DJI",
    ]

    /// Manufacturer name for a serial-number UAS ID, if the code is known.
    static func manufacturer(serial: String) -> String? {
        guard serial.count >= 5 else { return nil }
        return codes[String(serial.prefix(4)).uppercased()]
    }
}
