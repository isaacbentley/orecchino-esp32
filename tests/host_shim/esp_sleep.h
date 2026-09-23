#pragma once
#include "Arduino.h"
#define ESP_EXT1_WAKEUP_ALL_LOW 0
static inline int esp_sleep_enable_ext0_wakeup(gpio_num_t, int) { return 0; }
static inline int esp_sleep_enable_ext1_wakeup(uint64_t, int) { return 0; }
static inline void esp_deep_sleep_start() {}
