# Host shims for the radio cores

Just enough of the Arduino / ESP-IDF / NimBLE surface for
`firmware/common/tx_core.h`, `rx_core.h` and `tracker.h` to compile on a Mac
or Linux host, so `tests/core_test.cpp` can drive them: a fake clock
(`g_millis`), a `Serial` that records what it printed, a FreeRTOS queue, a
Wi-Fi TX capture (`g_wifi_tx`) and a NimBLE extended-advertising mock that
remembers which sets are active and every payload it was started with.
Nothing here talks to hardware.
