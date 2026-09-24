#pragma once
#include "Arduino.h"
typedef int esp_err_t;
#define ESP_OK 0
enum { WIFI_PS_NONE = 0 };
typedef enum { WIFI_SECOND_CHAN_NONE = 0 } wifi_second_chan_t;
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
static inline esp_err_t esp_wifi_set_channel(uint8_t ch, int) { extern uint8_t g_wifi_channel; g_wifi_channel = ch; return ESP_OK; }
static inline esp_err_t esp_wifi_set_promiscuous_filter(const wifi_promiscuous_filter_t*) { return ESP_OK; }
static inline esp_err_t esp_wifi_set_promiscuous_rx_cb(wifi_promiscuous_cb_t) { return ESP_OK; }
static inline esp_err_t esp_wifi_set_promiscuous(bool) { return ESP_OK; }
// Raw TX: every frame is captured with the time it was handed over; a test
// can make the driver refuse the next N (g_wifi_tx_refuse) or move the
// channel under the transmitter (g_wifi_channel).
extern std::vector<std::vector<uint8_t>> g_wifi_tx;
extern std::vector<uint32_t> g_wifi_tx_at;
extern int g_wifi_tx_refuse;
extern uint8_t g_wifi_channel;
#define ESP_ERR_NO_MEM 0x101
static inline esp_err_t esp_wifi_80211_tx(int, const void* buf, int len, bool) {
  if (g_wifi_tx_refuse > 0) { g_wifi_tx_refuse--; return ESP_ERR_NO_MEM; }
  g_wifi_tx.emplace_back((const uint8_t*)buf, (const uint8_t*)buf + len); g_wifi_tx_at.push_back(g_millis); return ESP_OK; }
typedef enum { WIFI_SEND_SUCCESS = 0, WIFI_SEND_FAIL } wifi_tx_status_t;
typedef struct { uint8_t* des_addr; uint8_t* src_addr; int ifidx; uint8_t* data; uint8_t data_len; int rate; wifi_tx_status_t tx_status; } esp_80211_tx_info_t;
typedef void (*esp_wifi_80211_tx_done_cb_t)(const esp_80211_tx_info_t*);
static inline esp_err_t esp_wifi_register_80211_tx_cb(esp_wifi_80211_tx_done_cb_t) { return ESP_OK; }
static inline esp_err_t esp_wifi_set_max_tx_power(int8_t) { return ESP_OK; }
static inline esp_err_t esp_wifi_get_max_tx_power(int8_t* p) { *p = 80; return ESP_OK; }
static inline esp_err_t esp_wifi_get_channel(uint8_t* p, wifi_second_chan_t* s) { *p = g_wifi_channel; *s = WIFI_SECOND_CHAN_NONE; return ESP_OK; }
