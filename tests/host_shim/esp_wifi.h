#pragma once
#include "Arduino.h"
typedef int esp_err_t;
#define ESP_OK 0
enum { WIFI_PS_NONE = 0 };
enum { WIFI_SECOND_CHAN_NONE = 0 };
enum { WIFI_IF_STA = 0 };
typedef enum { WIFI_PKT_MGMT = 0, WIFI_PKT_CTRL, WIFI_PKT_DATA, WIFI_PKT_MISC } wifi_promiscuous_pkt_type_t;
typedef struct { int8_t rssi; uint8_t channel; uint16_t sig_len; } wifi_pkt_rx_ctrl_t;
typedef struct { wifi_pkt_rx_ctrl_t rx_ctrl; uint8_t payload[]; } wifi_promiscuous_pkt_t;
typedef struct { uint32_t filter_mask; } wifi_promiscuous_filter_t;
#define WIFI_PROMIS_FILTER_MASK_MGMT 1
#define WIFI_PROMIS_FILTER_MASK_DATA 2
#define WIFI_PROMIS_FILTER_MASK_CTRL 4
typedef void (*wifi_promiscuous_cb_t)(void*, wifi_promiscuous_pkt_type_t);
static inline esp_err_t esp_wifi_set_ps(int) { return ESP_OK; }
static inline esp_err_t esp_wifi_set_channel(uint8_t, int) { return ESP_OK; }
static inline esp_err_t esp_wifi_set_promiscuous_filter(const wifi_promiscuous_filter_t*) { return ESP_OK; }
static inline esp_err_t esp_wifi_set_promiscuous_rx_cb(wifi_promiscuous_cb_t) { return ESP_OK; }
static inline esp_err_t esp_wifi_set_promiscuous(bool) { return ESP_OK; }
extern std::vector<std::vector<uint8_t>> g_wifi_tx;
static inline esp_err_t esp_wifi_80211_tx(int, const void* buf, int len, bool) { g_wifi_tx.emplace_back((const uint8_t*)buf, (const uint8_t*)buf + len); return ESP_OK; }
