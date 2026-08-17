import Foundation
import Testing
@testable import Orecchino

private func decode(_ s: String) throws -> RidMessage {
    try JSONDecoder().decode(RidMessage.self, from: Data(s.utf8))
}

@Suite struct RidMessageTests {
    @Test func heartbeatLine() throws {
        // Captured from firmware v0.4.0
        let m = try decode(#"{"type":"hb","up":34103,"wifi_frames":117,"ble_advs":4674,"rid":1,"rid_w":1,"rid_n":0,"rid_b":0,"pfail":0,"dropped":0,"seen":1,"ch":6,"ble":true,"ble_ext":true,"heap":103424}"#)
        #expect(m.type == "hb")
        #expect(m.wifi_frames == 117)
        #expect(m.ble_ext == true)
    }

    @Test func ridLineWithPhyAndNoVspeed() throws {
        // vspeed omitted = broadcast marked it unknown
        let m = try decode(#"{"type":"rid","src":"ble","mac":"AA:BB:CC:DD:EE:FF","rssi":-61,"phy":"coded","basic_id":[{"id_type":1,"ua_type":2,"uas_id":"1581F204C68D9A11"}],"loc":{"status":2,"lat":37.8039,"lon":-122.464,"alt_geo":100.0,"alt_baro":95.0,"height":60.0,"height_ref":0,"speed":5.0,"dir":90,"ts":1200.0}}"#)
        #expect(m.phy == "coded")
        #expect(m.loc?.vspeed == nil)
        #expect(m.loc?.speed == 5.0)
        #expect(m.basic_id?.first?.uas_id == "1581F204C68D9A11")
    }

    @Test func trackEndLineParses() throws {
        let m = try decode(#"{"type":"track_end","uas":"X","mac":"00:00:00:00:00:01","first_ms":1,"last_ms":2,"peak_rssi":-40,"max_height":60,"tfr":false}"#)
        #expect(m.type == "track_end")
    }
}

@Suite struct CRC32Tests {
    @Test func knownVector() {
        // Standard check value; must match the firmware's esp_rom_crc32_le
        // or every tile transfer would fail its fs_end verification.
        #expect(TileSync.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }

    @Test func empty() {
        #expect(TileSync.crc32(Data()) == 0x0000_0000)
    }
}

@Suite struct TileMathTests {
    @Test func deg2tileReferencePoints() {
        // Constants independently computed with the standard slippy-map formula
        let a = TileSync.deg2tile(lat: 37.7749, lon: -122.4194, z: 15)
        #expect(a.x == 5241 && a.y == 12665)
        let b = TileSync.deg2tile(lat: 37.7749, lon: -122.4194, z: 11)
        #expect(b.x == 327 && b.y == 791)
        let c = TileSync.deg2tile(lat: 37.8039, lon: -122.4640, z: 15)
        #expect(c.x == 5237 && c.y == 12662)
    }
}

@Suite struct MfrLookupTests {
    @Test func knownAndUnknownCodes() {
        #expect(MfrLookup.manufacturer(serial: "1581F204C68D9A11") == "DJI")
        #expect(MfrLookup.manufacturer(serial: "1581e0000000") == "DJI")
        #expect(MfrLookup.manufacturer(serial: "ZZZZ00000000") == nil)
        #expect(MfrLookup.manufacturer(serial: "158") == nil)  // too short
    }
}

@Suite struct SerialStatusTests {
    @Test func labels() {
        #expect(SerialStatus.connected("/dev/cu.usbserial-3110").label
                == "cu.usbserial-3110")
        #expect(!SerialStatus.searching.isConnected)
        #expect(SerialStatus.connected("x").isConnected)
    }
}
