import Foundation

/// Decodes the ANSI/CTA-2063-A manufacturer code (first 4 characters of a
/// Remote ID serial number). The CTA's code registry is not public, so this
/// table holds only codes verified against manufacturer documentation —
/// extend it as codes are confirmed. Owner/registration lookup is not
/// possible by design: FAA registration data is private and the UAS DOC
/// portal has no public API.
enum MfrLookup {
    /// Manufacturer name for a serial-number UAS ID, if the code is known.
    /// The table itself is generated into UasModels.swift from
    /// tools/uas_models.json, shared with the firmware.
    static func manufacturer(serial: String) -> String? {
        UasModels.manufacturer(serial: serial)
    }
}
