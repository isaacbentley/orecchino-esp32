# Host shims for the radio cores and screens

Just enough of the Arduino / ESP-IDF / NimBLE / epdiy / Arduino_GFX surface
for `firmware/common/tx_core.h`, `rx_core.h`, `tracker.h` and the T5 and
T-Embed screen code to compile on a Mac or Linux host, so
`tests/core_test.cpp`, `tests/t5_render_test.cpp` and
`tests/tembed_render_test.cpp` can drive them: a fake clock (`g_millis`), a
`Serial` that records what it printed, a FreeRTOS queue, an in-memory NVS
behind `Preferences` (`shim_nvs()`), a Wi-Fi TX capture (`g_wifi_tx`, with
the time of each frame, a way to make the driver refuse frames and a
channel that can drift), a NimBLE extended-advertising mock that behaves
like NimBLE and the controller (a running set cannot be reconfigured,
stop-all refuses while a set runs, data can be swapped in place, a set
count to grant) and logs every start, stop and data swap so a test can
replay the advertising events, and framebuffer stand-ins for the panels.
The BLE link's fake transport is not here: it lives in
`firmware/common/ble_link.h` itself (its non-`ESP_PLATFORM` half), with the
`ble_link_test_*` hooks the tests call. `tests/net_test.cpp` and
`tests/traffic_test.cpp` need no shims. Nothing here talks to hardware.
